package com.kreiseck.gptom_aidl_plugin;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.robolectric.Shadows.shadowOf;

import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.ResolveInfo;
import android.content.pm.ServiceInfo;
import android.os.IBinder;
import android.os.Looper;
import android.os.RemoteException;

import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.mockito.ArgumentCaptor;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

import java.lang.reflect.Field;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Executor;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import cn.nexgo.smartconnect.IGPTomInfoService;
import cn.nexgo.smartconnect.IGPTomLoginService;
import cn.nexgo.smartconnect.ISmartconnectService;
import cn.nexgo.smartconnect.listener.ITransactionRegisterListener;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** Binder-Aufrufe im Hintergrund, Wächter für Status und Register, feste Fehlertexte. */
@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34)
public class GptomThreadingTest {

  private static final String BENUTZER = "livia@melisse-nails.example";
  private static final String PASSWORT = "Geheim 1+2&3%#ä";
  private static final String TID = "12345678";
  private static final String INFO_JSON = "{\"isLoggedIn\":true,\"terminalId\":\"12345678\"}";

  /** Sammelt Aufgaben, statt sie auszuführen. runAll() arbeitet sie ab. */
  private static final class SammelExecutor implements Executor {
    final List<Runnable> aufgaben = new ArrayList<>();

    @Override
    public void execute(Runnable aufgabe) {
      aufgaben.add(aufgabe);
    }

    void runAll() {
      while (!aufgaben.isEmpty()) {
        aufgaben.remove(0).run();
      }
    }
  }

  private GptomAidlPlugin plugin;
  private MethodChannel.Result result;
  private SammelExecutor payment;
  private SammelExecutor account;

  @Before
  public void setUp() {
    plugin = new GptomAidlPlugin();

    FlutterPlugin.FlutterPluginBinding binding = mock(FlutterPlugin.FlutterPluginBinding.class);
    when(binding.getApplicationContext()).thenReturn(RuntimeEnvironment.getApplication());
    when(binding.getBinaryMessenger()).thenReturn(mock(BinaryMessenger.class));
    plugin.onAttachedToEngine(binding);

    payment = new SammelExecutor();
    account = new SammelExecutor();
    plugin.setExecutorsForTesting(payment, account);

    result = mock(MethodChannel.Result.class);
  }

  // ---------------------------------------------------------------------------
  // Hilfen
  // ---------------------------------------------------------------------------

  /** Setzt einen (gemockten) Service per Reflection, ohne echt zu binden. */
  private <T> T setzeService(String feld, Class<T> typ) throws Exception {
    T service = mock(typ);
    Field field = GptomAidlPlugin.class.getDeclaredField(feld);
    field.setAccessible(true);
    field.set(plugin, service);
    return service;
  }

  private void idleMainLooper() {
    shadowOf(Looper.getMainLooper()).idle();
  }

  /** Lässt die Zeit auf dem Main-Looper vergehen (postDelayed-Wächter). */
  private void warte(long millis) {
    shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(millis));
  }

  private void statusAbfrage(Integer timeoutMs, MethodChannel.Result antwort) {
    Map<String, Object> args = new HashMap<>();
    if (timeoutMs != null) {
      args.put("timeoutMs", timeoutMs);
    }
    plugin.onMethodCall(new MethodCall("getGpTomInfo", args), antwort);
  }

  private void register(MethodChannel.Result antwort) {
    Map<String, Object> args = new HashMap<>();
    args.put("registerJson", "{\"clientID\":\"kasse-1\"}");
    plugin.onMethodCall(new MethodCall("registerTransactionV2", args), antwort);
  }

  private Map<String, Object> loginArgs() {
    Map<String, Object> args = new HashMap<>();
    args.put("username", BENUTZER);
    args.put("password", PASSWORT);
    args.put("terminalId", TID);
    return args;
  }

  // ---------------------------------------------------------------------------
  // Status (getGPTomInfo)
  // ---------------------------------------------------------------------------

  @Test
  public void getGpTomInfo_laeuftNichtSofortAufDemAufruferThread() throws Exception {
    IGPTomInfoService info = setzeService("infoService", IGPTomInfoService.class);
    when(info.getGPTomInfo()).thenReturn(INFO_JSON);

    statusAbfrage(null, result);
    verify(info, never()).getGPTomInfo();

    account.runAll();
    idleMainLooper();
    verify(info, times(1)).getGPTomInfo();
    verify(result).success(INFO_JSON);

    // Der Wächter ist entfernt und meldet sich nicht nachträglich.
    warte(30000);
    verify(result, never()).error(anyString(), anyString(), any());
  }

  @Test
  public void getGpTomInfo_waechterNach20s_TIMEOUT() throws Exception {
    setzeService("infoService", IGPTomInfoService.class);

    statusAbfrage(null, result);

    warte(19999);
    verify(result, never()).error(anyString(), anyString(), any());

    warte(2);
    verify(result).error(eq("TIMEOUT"), anyString(), isNull());
  }

  @Test
  public void getGpTomInfo_timeoutMsAusArgument() throws Exception {
    setzeService("infoService", IGPTomInfoService.class);

    statusAbfrage(1000, result);

    warte(999);
    verify(result, never()).error(anyString(), anyString(), any());

    warte(2);
    verify(result).error(eq("TIMEOUT"), anyString(), isNull());
  }

  @Test
  public void getGpTomInfo_timeoutMsNull_keinWaechter() throws Exception {
    setzeService("infoService", IGPTomInfoService.class);

    statusAbfrage(0, result);

    warte(600000);
    verify(result, never()).error(anyString(), anyString(), any());
  }

  @Test
  public void getGpTomInfo_nachWaechter_wirdGPTomNichtMehrGefragt() throws Exception {
    IGPTomInfoService info = setzeService("infoService", IGPTomInfoService.class);
    when(info.getGPTomInfo()).thenReturn(INFO_JSON);

    statusAbfrage(1000, result);
    warte(1001);
    verify(result).error(eq("TIMEOUT"), anyString(), isNull());

    // Der Aufruf kommt erst nach dem Wächter dran: er ist schon beantwortet.
    account.runAll();
    idleMainLooper();
    verify(info, never()).getGPTomInfo();
    verify(result, never()).success(any());
  }

  // ---------------------------------------------------------------------------
  // Register (transactionRegisterV2)
  // ---------------------------------------------------------------------------

  @Test
  public void register_waechterNach30s_TIMEOUT() throws Exception {
    ISmartconnectService service = setzeService("gptomService", ISmartconnectService.class);

    register(result);
    payment.runAll();
    // GP tom nimmt den Aufruf an, meldet sich aber nie.
    verify(service).transactionRegisterV2(eq("{\"clientID\":\"kasse-1\"}"), any());

    warte(29999);
    verify(result, never()).error(anyString(), anyString(), any());

    warte(2);
    verify(result).error(eq("TIMEOUT"), anyString(), isNull());
  }

  @Test
  public void register_timeoutMsAusArgument() throws Exception {
    setzeService("gptomService", ISmartconnectService.class);

    Map<String, Object> args = new HashMap<>();
    args.put("registerJson", "{}");
    args.put("timeoutMs", 1000);
    plugin.onMethodCall(new MethodCall("registerTransactionV2", args), result);

    warte(999);
    verify(result, never()).error(anyString(), anyString(), any());

    warte(2);
    verify(result).error(eq("TIMEOUT"), anyString(), isNull());
  }

  @Test
  public void register_spaeteAntwortNachTimeout_einzigeAntwortBleibtTIMEOUT() throws Exception {
    ISmartconnectService service = setzeService("gptomService", ISmartconnectService.class);

    register(result);
    payment.runAll();
    ArgumentCaptor<ITransactionRegisterListener> listener =
        ArgumentCaptor.forClass(ITransactionRegisterListener.class);
    verify(service).transactionRegisterV2(anyString(), listener.capture());

    warte(30001);
    listener.getValue().onRegisterV2Result("{\"transactionID\":\"tx\"}");
    idleMainLooper();

    verify(result).error(eq("TIMEOUT"), anyString(), isNull());
    verify(result, never()).success(any());
  }

  // ---------------------------------------------------------------------------
  // Getrennte Executoren
  // ---------------------------------------------------------------------------

  @Test
  public void paymentUndAccount_getrennteExecutoren() throws Exception {
    IGPTomInfoService info = setzeService("infoService", IGPTomInfoService.class);
    ISmartconnectService service = setzeService("gptomService", ISmartconnectService.class);

    // Die Status-Abfrage hängt (Account-Executor läuft nicht).
    MethodChannel.Result status = mock(MethodChannel.Result.class);
    statusAbfrage(null, status);

    register(result);
    payment.runAll();

    ArgumentCaptor<ITransactionRegisterListener> listener =
        ArgumentCaptor.forClass(ITransactionRegisterListener.class);
    verify(service).transactionRegisterV2(anyString(), listener.capture());
    listener.getValue().onRegisterV2Result("{\"transactionID\":\"tx\"}");
    idleMainLooper();

    verify(result).success("{\"transactionID\":\"tx\"}");
    verify(info, never()).getGPTomInfo();
    verify(status, never()).success(any());
  }

  // ---------------------------------------------------------------------------
  // Feste Fehlertexte im Login-Pfad
  // ---------------------------------------------------------------------------

  @Test
  public void login_remoteExceptionMitGeheimnis_festerText() throws Exception {
    IGPTomLoginService login = setzeService("loginService", IGPTomLoginService.class);
    doThrow(new RemoteException(PASSWORT)).when(login).login(anyString());

    plugin.onMethodCall(new MethodCall("gpTomLogin", loginArgs()), result);
    verify(login, never()).login(anyString());

    account.runAll();
    idleMainLooper();

    verify(login).login(anyString());
    verify(result).error("LOGIN_ERROR", "Login-Aufruf an Genius Pay fehlgeschlagen.", null);
  }

  @Test
  public void logoutPasswortStatus_festeFehlertexte() throws Exception {
    IGPTomLoginService login = setzeService("loginService", IGPTomLoginService.class);
    IGPTomInfoService info = setzeService("infoService", IGPTomInfoService.class);
    doThrow(new RemoteException(PASSWORT)).when(login).logout();
    doThrow(new RemoteException(PASSWORT)).when(login).changePassword(anyString());
    when(info.getGPTomInfo()).thenThrow(new RemoteException(PASSWORT));

    MethodChannel.Result logout = mock(MethodChannel.Result.class);
    plugin.onMethodCall(new MethodCall("gpTomLogout", null), logout);

    MethodChannel.Result passwort = mock(MethodChannel.Result.class);
    Map<String, Object> args = new HashMap<>();
    args.put("oldPass", PASSWORT);
    args.put("newPass", PASSWORT + "!");
    args.put("validationOnly", true);
    plugin.onMethodCall(new MethodCall("gpTomChangePassword", args), passwort);

    MethodChannel.Result status = mock(MethodChannel.Result.class);
    statusAbfrage(null, status);

    account.runAll();
    idleMainLooper();

    verify(logout).error("LOGOUT_ERROR", "Logout-Aufruf an Genius Pay fehlgeschlagen.", null);
    verify(passwort).error(
        "CHANGE_PASSWORD_ERROR", "Passwortwechsel-Aufruf an Genius Pay fehlgeschlagen.", null);
    verify(status).error("INFO_ERROR", "Status-Abfrage an Genius Pay fehlgeschlagen.", null);
  }

  @Test
  public void login_erfolg_antwortetNachDemAufruf() throws Exception {
    IGPTomLoginService login = setzeService("loginService", IGPTomLoginService.class);

    plugin.onMethodCall(new MethodCall("gpTomLogin", loginArgs()), result);
    idleMainLooper();
    verify(result, never()).success(any());

    account.runAll();
    idleMainLooper();
    verify(login).login(anyString());
    verify(result).success(true);
  }

  // ---------------------------------------------------------------------------
  // Aufgabe läuft erst nach dem Trennen
  // ---------------------------------------------------------------------------

  @Test
  public void aufgabeNachUnbind_notBound() throws Exception {
    IGPTomLoginService login = setzeService("loginService", IGPTomLoginService.class);
    ISmartconnectService service = setzeService("gptomService", ISmartconnectService.class);

    plugin.onMethodCall(new MethodCall("gpTomLogin", loginArgs()), result);
    MethodChannel.Result register = mock(MethodChannel.Result.class);
    register(register);

    // Bevor die Aufgaben laufen, ist die Verbindung weg.
    setzeFeldNull("loginService");
    setzeFeldNull("gptomService");
    account.runAll();
    payment.runAll();
    idleMainLooper();

    verify(login, never()).login(anyString());
    verify(service, never()).transactionRegisterV2(anyString(), any());
    verify(result).error(eq("NOT_BOUND"), anyString(), isNull());
    verify(register).error(eq("NOT_BOUND"), anyString(), isNull());
  }

  private void setzeFeldNull(String feld) throws Exception {
    Field field = GptomAidlPlugin.class.getDeclaredField(feld);
    field.setAccessible(true);
    field.set(plugin, null);
  }

  // ---------------------------------------------------------------------------
  // Callback-Anmeldung im Account-Executor
  // ---------------------------------------------------------------------------

  @Test
  public void loginBindUndUnbind_callbackAnUndAbmeldungImHintergrund() throws Exception {
    GptomTrustTest.installiereGpTom(GptomTrustTest.PROD, GptomTrustTest.ZERT_A);
    IGPTomLoginService login = mock(IGPTomLoginService.class);
    IBinder binder = mock(IBinder.class);
    when(binder.queryLocalInterface(anyString())).thenReturn(login);
    shadowOf(RuntimeEnvironment.getApplication()).setComponentNameAndServiceForBindService(
        new ComponentName(GptomTrustTest.PROD, GptomTrustTest.PROD + ".Login"), binder);
    String action = "com.globalpayments.atom.BIND_TO_LOGIN_SERVICE";
    ResolveInfo resolve = new ResolveInfo();
    resolve.serviceInfo = new ServiceInfo();
    resolve.serviceInfo.packageName = GptomTrustTest.PROD;
    resolve.serviceInfo.name = GptomTrustTest.PROD + ".Login";
    shadowOf(RuntimeEnvironment.getApplication().getPackageManager())
        .addResolveInfoForIntent(new Intent(action).setPackage(GptomTrustTest.PROD), resolve);

    Map<String, Object> args = new HashMap<>();
    args.put("isDev", false);
    args.put("trustedSignatures", Collections.singletonList(GptomTrustTest.FP_A));
    plugin.onMethodCall(new MethodCall("bindLoginService", args), result);
    idleMainLooper();

    verify(result).success(true);
    verify(login, never()).registerCallback(any());
    account.runAll();
    verify(login).registerCallback(any());

    plugin.onMethodCall(new MethodCall("unbindLoginService", null), mock(MethodChannel.Result.class));
    idleMainLooper();
    verify(login, never()).unregisterCallback(any());
    account.runAll();
    verify(login).unregisterCallback(any());
  }

  // ---------------------------------------------------------------------------
  // Lebenszyklus
  // ---------------------------------------------------------------------------

  @Test
  public void detach_faehrtBeideExecutorenHerunter() {
    ExecutorService paymentPool = Executors.newSingleThreadExecutor();
    ExecutorService accountPool = Executors.newSingleThreadExecutor();
    plugin.setExecutorsForTesting(paymentPool, accountPool);

    plugin.onDetachedFromEngine(mock(FlutterPlugin.FlutterPluginBinding.class));

    assertTrue(paymentPool.isShutdown());
    assertTrue(accountPool.isShutdown());
  }

  @Test
  public void nachDetach_aufrufBeantwortetNotBound() throws Exception {
    setzeService("infoService", IGPTomInfoService.class);
    plugin.onDetachedFromEngine(mock(FlutterPlugin.FlutterPluginBinding.class));
    setzeService("infoService", IGPTomInfoService.class);

    statusAbfrage(null, result);
    idleMainLooper();

    verify(result).error(eq("NOT_BOUND"), anyString(), isNull());
    assertEquals(0, account.aufgaben.size());
  }
}
