package com.kreiseck.gptom_aidl_plugin;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.robolectric.Shadows.shadowOf;

import android.content.ComponentName;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.os.IBinder;
import android.os.Looper;

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.mockito.ArgumentCaptor;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

import java.lang.reflect.Field;
import java.nio.ByteBuffer;
import java.time.Duration;
import java.util.HashMap;
import java.util.Map;

import cn.nexgo.smartconnect.ISmartconnectService;
import cn.nexgo.smartconnect.listener.ITransactionResultListener;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.StandardMethodCodec;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34)
public class GptomAidlPluginTest {

  private GptomAidlPlugin plugin;
  private MethodChannel.Result result;
  private BinaryMessenger messenger;

  @Before
  public void setUp() {
    plugin = new GptomAidlPlugin();

    messenger = mock(BinaryMessenger.class);
    FlutterPlugin.FlutterPluginBinding binding = mock(FlutterPlugin.FlutterPluginBinding.class);
    when(binding.getApplicationContext()).thenReturn(RuntimeEnvironment.getApplication());
    when(binding.getBinaryMessenger()).thenReturn(messenger);
    plugin.onAttachedToEngine(binding);

    result = mock(MethodChannel.Result.class);
  }

  /** SingleResult antwortet über den Main-Looper – Robolectric muss ihn abarbeiten. */
  private void idleMainLooper() {
    shadowOf(Looper.getMainLooper()).idle();
  }

  @Test
  public void unbekannteMethode_liefertNotImplemented() {
    plugin.onMethodCall(new MethodCall("gibtEsNicht", null), result);
    verify(result).notImplemented();
  }

  @Test
  public void existGpTomApp_ohneInstallierteApp_false() {
    Map<String, Object> args = new HashMap<>();
    args.put("isDev", false);
    plugin.onMethodCall(new MethodCall("existGpTomApp", args), result);
    verify(result).success(false);
  }

  @Test
  public void existGpTomApp_mitInstallierterApp_true() {
    PackageInfo packageInfo = new PackageInfo();
    packageInfo.packageName = "com.globalpayments.atom";
    packageInfo.applicationInfo = new ApplicationInfo();
    packageInfo.applicationInfo.packageName = "com.globalpayments.atom";
    shadowOf(RuntimeEnvironment.getApplication().getPackageManager())
        .installPackage(packageInfo);

    Map<String, Object> args = new HashMap<>();
    args.put("isDev", false);
    plugin.onMethodCall(new MethodCall("existGpTomApp", args), result);
    verify(result).success(true);
  }

  @Test
  public void registerTransactionV2_ohneBindung_notBound() {
    Map<String, Object> args = new HashMap<>();
    args.put("registerJson", "{}");
    plugin.onMethodCall(new MethodCall("registerTransactionV2", args), result);
    idleMainLooper();
    verify(result).error(eq("NOT_BOUND"), anyString(), isNull());
  }

  @Test
  public void requestTransactionV2_ohneBindung_notBound() {
    Map<String, Object> args = new HashMap<>();
    args.put("requestJson", "{\"transactionID\":\"tx\"}");
    plugin.onMethodCall(new MethodCall("requestTransactionV2", args), result);
    idleMainLooper();
    verify(result).error(eq("NOT_BOUND"), anyString(), isNull());
  }

  @Test
  public void stateRequest_ohneBindung_notBound() {
    Map<String, Object> args = new HashMap<>();
    args.put("transactionId", "tx");
    plugin.onMethodCall(new MethodCall("stateRequest", args), result);
    idleMainLooper();
    verify(result).error(eq("NOT_BOUND"), anyString(), isNull());
  }

  @Test
  public void gpTomLogin_ohneBindung_notBound() {
    Map<String, Object> args = new HashMap<>();
    args.put("username", "u");
    args.put("password", "p");
    args.put("terminalId", "t");
    plugin.onMethodCall(new MethodCall("gpTomLogin", args), result);
    idleMainLooper();
    verify(result).error(eq("NOT_BOUND"), anyString(), isNull());
  }

  @Test
  public void requestTransactionV2_entferntSteuerfelderUndBehaeltCentInts() throws Exception {
    ISmartconnectService service = bindeService();

    Map<String, Object> args = new HashMap<>();
    args.put("requestJson",
        "{\"transactionID\":\"tx\",\"transactionType\":1,\"amount\":1111,"
            + "\"openGptomUI\":false,\"redirect\":true,\"timeoutMs\":60000}");
    plugin.onMethodCall(new MethodCall("requestTransactionV2", args), result);

    ArgumentCaptor<String> jsonCaptor = ArgumentCaptor.forClass(String.class);
    verify(service).transactionRequestV2(jsonCaptor.capture(), any());

    JsonObject sent = JsonParser.parseString(jsonCaptor.getValue()).getAsJsonObject();
    // Steuerfelder gehören nicht ins GPTom-Request-JSON
    assertFalse(sent.has("openGptomUI"));
    assertFalse(sent.has("redirect"));
    assertFalse(sent.has("timeoutMs"));
    // Cent-Betrag bleibt Ganzzahl (nicht "1111.0")
    assertEquals("1111", sent.get("amount").getAsString());
    assertEquals("tx", sent.get("transactionID").getAsString());
  }

  // ---------------------------------------------------------------------------
  // Wächter auf requestTransactionV2
  // ---------------------------------------------------------------------------

  /** Setzt den (gemockten) Zahlungs-Service, ohne echt zu binden. */
  private ISmartconnectService bindeService() throws Exception {
    ISmartconnectService service = mock(ISmartconnectService.class);
    Field field = GptomAidlPlugin.class.getDeclaredField("gptomService");
    field.setAccessible(true);
    field.set(plugin, service);
    return service;
  }

  private void starteTransaktion(long timeoutMs) {
    Map<String, Object> args = new HashMap<>();
    args.put("requestJson",
        "{\"transactionID\":\"tx\",\"transactionType\":1,\"amount\":1111,"
            + "\"openGptomUI\":false,\"timeoutMs\":" + timeoutMs + "}");
    plugin.onMethodCall(new MethodCall("requestTransactionV2", args), result);
  }

  /** Lässt die Zeit auf dem Main-Looper vergehen (postDelayed-Wächter). */
  private void warte(long millis) {
    shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(millis));
  }

  @Test
  public void requestTransactionV2_ohneAntwort_liefertTimeout() throws Exception {
    // Ohne Wächter wartet die Kasse unbegrenzt, wenn GP tom nie antwortet
    // (App weggewischt, vom System beendet).
    bindeService();
    starteTransaktion(500);

    warte(499);
    verify(result, never()).error(anyString(), anyString(), any());

    warte(2);
    verify(result).error(eq("TIMEOUT"), anyString(), isNull());
  }

  @Test
  public void requestTransactionV2_antwortRechtzeitig_keinTimeout() throws Exception {
    ISmartconnectService service = bindeService();
    starteTransaktion(500);

    ArgumentCaptor<ITransactionResultListener> listenerCaptor =
        ArgumentCaptor.forClass(ITransactionResultListener.class);
    verify(service).transactionRequestV2(anyString(), listenerCaptor.capture());
    listenerCaptor.getValue().onTransactionV2Result("{\"result\":0}");

    warte(1000);
    verify(result).success("{\"result\":0}");
    verify(result, never()).error(anyString(), anyString(), any());
  }

  @Test
  public void requestTransactionV2_spaeteAntwort_gehtAlsEreignisAnDart() throws Exception {
    ISmartconnectService service = bindeService();
    starteTransaktion(100);

    ArgumentCaptor<ITransactionResultListener> listenerCaptor =
        ArgumentCaptor.forClass(ITransactionResultListener.class);
    verify(service).transactionRequestV2(anyString(), listenerCaptor.capture());

    warte(200);
    verify(result).error(eq("TIMEOUT"), anyString(), isNull());

    // GP tom antwortet doch noch: der Kanal ist gesperrt, das Ergebnis darf
    // aber nicht verloren gehen.
    listenerCaptor.getValue().onTransactionV2Result("{\"result\":0,\"amsID\":\"ams-1\"}");
    warte(10);

    verify(result, never()).success(any());
    MethodCall push = letzterPushAnDart();
    assertNotNull(push);
    assertEquals("onLateTransactionResult", push.method);
    assertEquals("{\"result\":0,\"amsID\":\"ams-1\"}", push.arguments);
  }

  @Test
  public void requestTransactionV2_ohneTimeoutFeld_nutztDenStandard() throws Exception {
    bindeService();
    Map<String, Object> args = new HashMap<>();
    args.put("requestJson", "{\"transactionID\":\"tx\",\"transactionType\":1}");
    plugin.onMethodCall(new MethodCall("requestTransactionV2", args), result);

    // Standard sind 240 Sekunden – nach einer Minute darf noch nichts kommen.
    warte(60000);
    verify(result, never()).error(anyString(), anyString(), any());

    warte(181000);
    verify(result).error(eq("TIMEOUT"), anyString(), isNull());
  }

  /** Letzter Aufruf, den der Plugin-Code über den MethodChannel nach Dart geschickt hat. */
  private MethodCall letzterPushAnDart() {
    ArgumentCaptor<ByteBuffer> nachricht = ArgumentCaptor.forClass(ByteBuffer.class);
    verify(messenger, atLeastOnce())
        .send(eq("gptom_aidl_plugin"), nachricht.capture(), any());
    ByteBuffer letzte = nachricht.getValue();
    letzte.position(0);
    return StandardMethodCodec.INSTANCE.decodeMethodCall(letzte);
  }

  @Test
  public void bindService_nachErfolg_keinSpaetesFalse() {
    // Der Bind-Wächter darf nach einer geglückten Verbindung nicht mehr
    // feuern (er hielte sonst 5 s lang eine Antwort in der Hinterhand).
    ComponentName name = new ComponentName(
        "com.globalpayments.atom",
        "com.globalpayments.atom.data.external.api.NexgoAPIService");
    shadowOf(RuntimeEnvironment.getApplication())
        .setComponentNameAndServiceForBindService(name, mock(IBinder.class));

    Map<String, Object> args = new HashMap<>();
    args.put("isDev", false);
    plugin.onMethodCall(new MethodCall("bindService", args), result);

    warte(10);
    verify(result).success(true);

    // Entscheidend: der Wächter steht nicht mehr in der Warteschlange.
    assertEquals(
        Duration.ZERO,
        shadowOf(Looper.getMainLooper()).getNextScheduledTaskTime());

    warte(10000);
    verify(result, never()).success(false);
  }
}
