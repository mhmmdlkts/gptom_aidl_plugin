package com.kreiseck.gptom_aidl_plugin;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.robolectric.Shadows.shadowOf;

import android.app.Application;
import android.content.ComponentName;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.ServiceConnection;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.ResolveInfo;
import android.content.pm.ServiceInfo;
import android.content.pm.Signature;
import android.content.pm.SigningInfo;
import android.os.Build;
import android.os.IBinder;
import android.os.IInterface;
import android.os.Looper;

import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.mockito.ArgumentCaptor;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowSigningInfo;

import java.lang.reflect.Field;
import java.time.Duration;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import cn.nexgo.smartconnect.IGPTomInfoService;
import cn.nexgo.smartconnect.IGPTomLoginService;
import cn.nexgo.smartconnect.ISmartconnectService;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** Signaturprüfung der GP-tom-App und getrenntes isDev je Verbindung. */
@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34)
public class GptomTrustTest {

  static final String PROD = "com.globalpayments.atom";
  static final String DEV = "com.globalpayments.atom.dev";
  private static final String PAYMENT_SERVICE_CLASS =
      "com.globalpayments.atom.data.external.api.NexgoAPIService";
  private static final String TRUST_PREFS = "gptom_aidl_plugin_trust";

  /** Feste Test-Zertifikate (keine echten Schlüssel). */
  static final Signature ZERT_A = new Signature(new byte[] {1, 2, 3, 4});
  static final Signature ZERT_B = new Signature(new byte[] {5, 6, 7, 8});

  /** SHA-256 von ZERT_A bzw. ZERT_B, Großbuchstaben mit Doppelpunkten. */
  static final String FP_A =
      "9F:64:A7:47:E1:B9:7F:13:1F:AB:B6:B4:47:29:6C:9B:"
          + "6F:02:01:E7:9F:B3:C5:35:6E:6C:77:E8:9B:6A:80:6A";
  static final String FP_B =
      "55:E5:50:9F:80:52:99:82:94:26:6E:E5:B5:0C:B5:92:"
          + "93:81:91:FB:5D:67:F7:3C:AC:2E:60:B0:27:6B:1B:DD";

  private GptomAidlPlugin plugin;
  private MethodChannel.Result result;

  @Before
  public void setUp() {
    plugin = new GptomAidlPlugin();

    BinaryMessenger messenger = mock(BinaryMessenger.class);
    FlutterPlugin.FlutterPluginBinding binding = mock(FlutterPlugin.FlutterPluginBinding.class);
    when(binding.getApplicationContext()).thenReturn(RuntimeEnvironment.getApplication());
    when(binding.getBinaryMessenger()).thenReturn(messenger);
    plugin.onAttachedToEngine(binding);

    result = mock(MethodChannel.Result.class);
  }

  // ---------------------------------------------------------------------------
  // Hilfen
  // ---------------------------------------------------------------------------

  /**
   * Installiert GP tom mit dem aktuellen Signatur-Zertifikat und optional
   * früheren Zertifikaten (Key-Rotation).
   */
  @SuppressWarnings("deprecation")
  static void installiereGpTom(String paket, Signature aktuell, Signature... frueher) {
    PackageInfo info = new PackageInfo();
    info.packageName = paket;
    info.versionName = "1.80.0";
    info.versionCode = 180;
    info.applicationInfo = new ApplicationInfo();
    info.applicationInfo.packageName = paket;
    if (Build.VERSION.SDK_INT >= 28) {
      info.signingInfo = signingInfo(aktuell, frueher);
    } else {
      info.signatures = new Signature[] {aktuell};
    }
    shadowOf(RuntimeEnvironment.getApplication().getPackageManager()).installPackage(info);
  }

  private static SigningInfo signingInfo(Signature aktuell, Signature... frueher) {
    SigningInfo signingInfo = new SigningInfo();
    ShadowSigningInfo shadow = shadowOf(signingInfo);
    shadow.setSignatures(new Signature[] {aktuell});
    if (frueher.length > 0) {
      // Android liefert in getSigningCertificateHistory() die ganze Kette,
      // das aktuelle Zertifikat zuletzt. Der Shadow gibt die vergangenen
      // Zertifikate unverändert zurück, deshalb gehört das aktuelle dazu.
      Signature[] kette = Arrays.copyOf(frueher, frueher.length + 1);
      kette[frueher.length] = aktuell;
      shadow.setPastSigningCertificates(kette);
    }
    return signingInfo;
  }

  private void idleMainLooper() {
    shadowOf(Looper.getMainLooper()).idle();
  }

  private Application app() {
    return RuntimeEnvironment.getApplication();
  }

  private String gemerkterFingerprint(String paket) {
    return app().getSharedPreferences(TRUST_PREFS, Context.MODE_PRIVATE).getString(paket, null);
  }

  /** Lässt einen Bind auf den Payment-Service von GP tom sofort gelingen. */
  private void paymentServiceVerfuegbar() {
    shadowOf(app()).setComponentNameAndServiceForBindService(
        new ComponentName(PROD, PAYMENT_SERVICE_CLASS), mock(IBinder.class));
  }

  private Map<String, Object> bindArgs(boolean isDev, List<String> pins) {
    Map<String, Object> args = new HashMap<>();
    args.put("isDev", isDev);
    args.put("trustedSignatures", pins);
    return args;
  }

  // ---------------------------------------------------------------------------
  // Pins
  // ---------------------------------------------------------------------------

  @Test
  public void pinPasst_trustedPinned() {
    installiereGpTom(PROD, ZERT_A);

    GptomAidlPlugin.TrustResult trust =
        plugin.verifyTarget(PROD, Arrays.asList(FP_B, FP_A), true);

    assertTrue(trust.installed);
    assertTrue(trust.trusted);
    assertEquals("pinned", trust.source);
    assertEquals(Collections.singletonList(FP_A), trust.signatureSha256);
    // Mit Pins wird nichts gemerkt.
    assertNull(gemerkterFingerprint(PROD));
  }

  @Test
  public void pinPasstNicht_mismatch_undBindRuftNichtsAuf() {
    installiereGpTom(PROD, ZERT_A);
    paymentServiceVerfuegbar();

    GptomAidlPlugin.TrustResult trust =
        plugin.verifyTarget(PROD, Collections.singletonList(FP_B), true);
    assertTrue(trust.installed);
    assertFalse(trust.trusted);
    assertEquals("mismatch", trust.source);

    plugin.onMethodCall(
        new MethodCall("bindService", bindArgs(false, Collections.singletonList(FP_B))), result);
    idleMainLooper();

    verify(result).success(false);
    verify(result, never()).success(true);
    assertTrue(shadowOf(app()).getBoundServiceConnections().isEmpty());
  }

  @Test
  public void pinPasst_bindWirdAufgebaut() {
    installiereGpTom(PROD, ZERT_A);
    paymentServiceVerfuegbar();

    plugin.onMethodCall(
        new MethodCall("bindService", bindArgs(false, Collections.singletonList(FP_A))), result);
    idleMainLooper();

    verify(result).success(true);
    assertEquals(1, shadowOf(app()).getBoundServiceConnections().size());
  }

  @Test
  public void pinPasstNicht_trenntBestehendeZahlungsverbindung() {
    installiereGpTom(PROD, ZERT_A);
    paymentServiceVerfuegbar();
    plugin.onMethodCall(
        new MethodCall("bindService", bindArgs(false, Collections.singletonList(FP_A))), result);
    idleMainLooper();
    verify(result).success(true);

    // Neue Pins zur Laufzeit, die zur installierten App nicht passen.
    MethodChannel.Result zweiterBind = mock(MethodChannel.Result.class);
    plugin.onMethodCall(
        new MethodCall("bindService", bindArgs(false, Collections.singletonList(FP_B))),
        zweiterBind);
    idleMainLooper();
    verify(zweiterBind).success(false);
    assertEquals(1, shadowOf(app()).getUnboundServiceConnections().size());

    // Zahlungen gehen nicht mehr über die alte Verbindung.
    MethodChannel.Result register = mock(MethodChannel.Result.class);
    Map<String, Object> args = new HashMap<>();
    args.put("registerJson", "{}");
    plugin.onMethodCall(new MethodCall("registerTransactionV2", args), register);
    idleMainLooper();
    verify(register).error(eq("NOT_BOUND"), anyString(), any());
  }

  @Test
  public void pinPasstNicht_loginUndInfoBindRufenNichtsAuf() {
    installiereGpTom(PROD, ZERT_A);
    List<String> falscherPin = Collections.singletonList(FP_B);

    MethodChannel.Result loginResult = mock(MethodChannel.Result.class);
    plugin.onMethodCall(new MethodCall("bindLoginService", bindArgs(false, falscherPin)), loginResult);
    MethodChannel.Result infoResult = mock(MethodChannel.Result.class);
    plugin.onMethodCall(new MethodCall("bindInfoService", bindArgs(false, falscherPin)), infoResult);
    idleMainLooper();

    verify(loginResult).success(false);
    verify(infoResult).success(false);
    assertTrue(shadowOf(app()).getBoundServiceConnections().isEmpty());
  }

  // ---------------------------------------------------------------------------
  // Erstvertrauen (trust on first use)
  // ---------------------------------------------------------------------------

  @Test
  public void ohnePins_erstvertrauen_wirdGespeichert() {
    installiereGpTom(PROD, ZERT_A);

    GptomAidlPlugin.TrustResult erst =
        plugin.verifyTarget(PROD, Collections.<String>emptyList(), true);
    assertTrue(erst.trusted);
    assertEquals("firstUse", erst.source);
    assertEquals(FP_A, gemerkterFingerprint(PROD));

    GptomAidlPlugin.TrustResult danach =
        plugin.verifyTarget(PROD, Collections.<String>emptyList(), true);
    assertTrue(danach.trusted);
    assertEquals("firstUse", danach.source);
  }

  @Test
  public void ohnePins_andereSignaturDanach_mismatch() {
    installiereGpTom(PROD, ZERT_A);
    plugin.verifyTarget(PROD, Collections.<String>emptyList(), true);

    // Ersetzt durch eine App mit fremdem Schlüssel.
    installiereGpTom(PROD, ZERT_B);
    GptomAidlPlugin.TrustResult trust =
        plugin.verifyTarget(PROD, Collections.<String>emptyList(), true);

    assertTrue(trust.installed);
    assertFalse(trust.trusted);
    assertEquals("mismatch", trust.source);
    // Der gemerkte Fingerprint bleibt.
    assertEquals(FP_A, gemerkterFingerprint(PROD));
  }

  @Test
  public void reset_erlaubtNeuesErstvertrauen() {
    installiereGpTom(PROD, ZERT_A);
    plugin.verifyTarget(PROD, Collections.<String>emptyList(), true);
    installiereGpTom(PROD, ZERT_B);
    assertEquals("mismatch",
        plugin.verifyTarget(PROD, Collections.<String>emptyList(), true).source);

    Map<String, Object> args = new HashMap<>();
    args.put("isDev", false);
    plugin.onMethodCall(new MethodCall("resetTrustedSignature", args), result);
    idleMainLooper();
    verify(result).success(true);
    assertNull(gemerkterFingerprint(PROD));

    GptomAidlPlugin.TrustResult trust =
        plugin.verifyTarget(PROD, Collections.<String>emptyList(), true);
    assertTrue(trust.trusted);
    assertEquals("firstUse", trust.source);
    assertEquals(FP_B, gemerkterFingerprint(PROD));
  }

  // ---------------------------------------------------------------------------
  // Notschalter, nicht installiert, Key-Rotation, alte API
  // ---------------------------------------------------------------------------

  @Test
  public void verifyAus_unchecked_trusted() {
    installiereGpTom(PROD, ZERT_A);

    GptomAidlPlugin.TrustResult trust =
        plugin.verifyTarget(PROD, Collections.singletonList(FP_B), false);

    assertTrue(trust.installed);
    assertTrue(trust.trusted);
    assertEquals("unchecked", trust.source);
    assertEquals(Collections.singletonList(FP_A), trust.signatureSha256);
    assertNull(gemerkterFingerprint(PROD));
  }

  @Test
  public void nichtInstalliert_notInstalled() {
    GptomAidlPlugin.TrustResult trust =
        plugin.verifyTarget(PROD, Collections.<String>emptyList(), true);

    assertFalse(trust.installed);
    assertFalse(trust.trusted);
    assertEquals("notInstalled", trust.source);
    assertTrue(trust.signatureSha256.isEmpty());
    assertNull(trust.versionName);
    assertNull(trust.versionCode);
    assertNull(gemerkterFingerprint(PROD));
  }

  @Test
  public void keyRotation_alterPinInHistorie_trusted() {
    // Global Payments hat von ZERT_A auf ZERT_B rotiert.
    installiereGpTom(PROD, ZERT_B, ZERT_A);

    GptomAidlPlugin.TrustResult trust =
        plugin.verifyTarget(PROD, Collections.singletonList(FP_A), true);

    assertTrue(trust.trusted);
    assertEquals("pinned", trust.source);
    // Gemeldet wird das aktuelle Zertifikat.
    assertEquals(Collections.singletonList(FP_B), trust.signatureSha256);
  }

  @Test
  @Config(sdk = 27)
  public void apiUnter28_signaturesFeld() {
    installiereGpTom(PROD, ZERT_A);

    GptomAidlPlugin.TrustResult pin =
        plugin.verifyTarget(PROD, Collections.singletonList(FP_A), true);
    assertTrue(pin.trusted);
    assertEquals("pinned", pin.source);
    assertEquals(Collections.singletonList(FP_A), pin.signatureSha256);

    assertEquals("mismatch",
        plugin.verifyTarget(PROD, Collections.singletonList(FP_B), true).source);
  }

  // ---------------------------------------------------------------------------
  // isDev je Verbindung
  // ---------------------------------------------------------------------------

  @Test
  public void isDevGetrennt_infoDevVeraendertPaymentNicht() {
    Map<String, Object> payment = new HashMap<>();
    payment.put("isDev", false);
    plugin.onMethodCall(new MethodCall("bindService", payment), mock(MethodChannel.Result.class));

    Map<String, Object> info = new HashMap<>();
    info.put("isDev", true);
    plugin.onMethodCall(new MethodCall("bindInfoService", info), mock(MethodChannel.Result.class));
    idleMainLooper();

    assertEquals(PROD, plugin.paymentPackageForTesting());
  }

  /**
   * Lässt jeden Bind sofort gelingen. Der Binder liefert den gemockten
   * Service, damit registerCallback & Co. nichts Echtes aufrufen.
   */
  private void dienstVerfuegbar(IInterface service) {
    IBinder binder = mock(IBinder.class);
    when(binder.queryLocalInterface(anyString())).thenReturn(service);
    shadowOf(app()).setComponentNameAndServiceForBindService(
        new ComponentName(PROD, PROD + ".Dienst"), binder);
  }

  /** Meldet einen Service per Action in PROD und DEV an (für queryIntentServices). */
  private void actionServiceAngemeldet(String action) {
    for (String paket : new String[] {PROD, DEV}) {
      ResolveInfo info = new ResolveInfo();
      info.serviceInfo = new ServiceInfo();
      info.serviceInfo.packageName = paket;
      info.serviceInfo.name = paket + ".Dienst";
      shadowOf(app().getPackageManager())
          .addResolveInfoForIntent(new Intent(action).setPackage(paket), info);
    }
  }

  /** Paket, an das ein Bind-Intent geht (explizit per Component oder per setPackage). */
  private static String zielpaket(Intent intent) {
    assertNotNull(intent);
    return intent.getComponent() != null
        ? intent.getComponent().getPackageName()
        : intent.getPackage();
  }

  /**
   * Bind auf PROD, erneuter Bind mit gleichem isDev (Verbindung bleibt), dann
   * Wechsel auf DEV (alte Verbindung wird getrennt, neuer Bind an DEV).
   */
  private void pruefeIsDevWechsel(String methode) {
    installiereGpTom(PROD, ZERT_A);
    installiereGpTom(DEV, ZERT_A);
    List<String> pins = Collections.singletonList(FP_A);

    MethodChannel.Result erster = mock(MethodChannel.Result.class);
    plugin.onMethodCall(new MethodCall(methode, bindArgs(false, pins)), erster);
    idleMainLooper();
    verify(erster).success(true);
    assertEquals(PROD, zielpaket(shadowOf(app()).getNextStartedService()));

    // Gleiches isDev: Verbindung bleibt, kein neuer Bind.
    MethodChannel.Result gleich = mock(MethodChannel.Result.class);
    plugin.onMethodCall(new MethodCall(methode, bindArgs(false, pins)), gleich);
    idleMainLooper();
    verify(gleich).success(true);
    assertNull(shadowOf(app()).getNextStartedService());
    assertEquals(1, shadowOf(app()).getBoundServiceConnections().size());
    assertTrue(shadowOf(app()).getUnboundServiceConnections().isEmpty());

    // Wechsel auf DEV: alte Verbindung zuerst trennen, dann neu binden.
    MethodChannel.Result wechsel = mock(MethodChannel.Result.class);
    plugin.onMethodCall(new MethodCall(methode, bindArgs(true, pins)), wechsel);
    idleMainLooper();
    verify(wechsel).success(true);
    assertEquals(1, shadowOf(app()).getUnboundServiceConnections().size());
    assertEquals(DEV, zielpaket(shadowOf(app()).getNextStartedService()));
  }

  @Test
  public void isDevWechsel_payment_bautVerbindungNeuAuf() {
    dienstVerfuegbar(mock(ISmartconnectService.class));

    pruefeIsDevWechsel("bindService");

    assertEquals(DEV, plugin.paymentPackageForTesting());
  }

  @Test
  public void isDevWechsel_login_bautVerbindungNeuAuf() throws Exception {
    IGPTomLoginService login = mock(IGPTomLoginService.class);
    dienstVerfuegbar(login);
    actionServiceAngemeldet("com.globalpayments.atom.BIND_TO_LOGIN_SERVICE");

    pruefeIsDevWechsel("bindLoginService");

    // Die alte Verbindung hat ihren Callback abgemeldet.
    verify(login).unregisterCallback(any());
  }

  @Test
  public void isDevWechsel_info_bautVerbindungNeuAuf() throws Exception {
    IGPTomInfoService info = mock(IGPTomInfoService.class);
    dienstVerfuegbar(info);
    actionServiceAngemeldet("com.globalpayments.atom.BIND_TO_INFO_SERVICE");

    pruefeIsDevWechsel("bindInfoService");

    verify(info).unregisterCallback(any());
  }

  // ---------------------------------------------------------------------------
  // Bind-Wächter
  // ---------------------------------------------------------------------------

  /** Hängt das Plugin an einen anderen Kontext (ersetzt das aus setUp). */
  private void pluginMitKontext(Context kontext) {
    plugin = new GptomAidlPlugin();
    FlutterPlugin.FlutterPluginBinding binding = mock(FlutterPlugin.FlutterPluginBinding.class);
    when(binding.getApplicationContext()).thenReturn(kontext);
    when(binding.getBinaryMessenger()).thenReturn(mock(BinaryMessenger.class));
    plugin.onAttachedToEngine(binding);
  }

  @Test
  public void bindWaechter_haengenderBindNachIsDevWechsel_antwortetFalseGenauEinmal() {
    installiereGpTom(PROD, ZERT_A);
    installiereGpTom(DEV, ZERT_A);
    dienstVerfuegbar(mock(ISmartconnectService.class));
    // Prod nimmt den Bind an, meldet sich aber nie (onServiceConnected bleibt aus).
    // Robolectric selbst ruft onServiceConnected immer auf, deshalb der Wrapper.
    pluginMitKontext(new ContextWrapper(app()) {
      @Override
      public boolean bindService(Intent service, ServiceConnection conn, int flags) {
        if (PROD.equals(zielpaket(service))) {
          return true;
        }
        return super.bindService(service, conn, flags);
      }
    });
    List<String> pins = Collections.singletonList(FP_A);

    MethodChannel.Result erster = mock(MethodChannel.Result.class);
    plugin.onMethodCall(new MethodCall("bindService", bindArgs(false, pins)), erster);
    idleMainLooper();
    verify(erster, never()).success(any());

    // Wechsel auf DEV, der neue Bind verbindet sofort.
    MethodChannel.Result zweiter = mock(MethodChannel.Result.class);
    plugin.onMethodCall(new MethodCall("bindService", bindArgs(true, pins)), zweiter);
    idleMainLooper();
    verify(zweiter).success(true);
    // Der verworfene Bind wird sofort beantwortet, nicht erst vom Wächter.
    verify(erster).success(false);

    // Nach Ablauf des Wächters: weiterhin genau eine Antwort.
    shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(6000));
    verify(erster, times(1)).success(any());
    verify(erster, times(1)).success(false);
    verify(zweiter, times(1)).success(any());
  }

  // ---------------------------------------------------------------------------
  // openGptomUI
  // ---------------------------------------------------------------------------

  /** Meldet für GP tom eine Start-Activity an, damit getLaunchIntentForPackage greift. */
  private void gpTomStartActivity() throws Exception {
    ComponentName start = new ComponentName(PROD, PROD + ".MainActivity");
    shadowOf(app().getPackageManager()).addActivityIfNotPresent(start);
    IntentFilter filter = new IntentFilter(Intent.ACTION_MAIN);
    filter.addCategory(Intent.CATEGORY_LAUNCHER);
    shadowOf(app().getPackageManager()).addIntentFilterForActivity(start, filter);
  }

  /** Setzt den (gemockten) Zahlungs-Service, ohne echt zu binden. */
  private void setzePaymentService() throws Exception {
    Field field = GptomAidlPlugin.class.getDeclaredField("gptomService");
    field.setAccessible(true);
    field.set(plugin, mock(ISmartconnectService.class));
  }

  private void verkaufMitGpTomUi() {
    Map<String, Object> args = new HashMap<>();
    args.put("requestJson",
        "{\"transactionID\":\"tx\",\"transactionType\":1,\"amount\":1111,"
            + "\"openGptomUI\":true,\"timeoutMs\":0}");
    plugin.onMethodCall(new MethodCall("requestTransactionV2", args), result);
  }

  @Test
  public void openGptomUI_vertraut_startetGpTom() throws Exception {
    installiereGpTom(PROD, ZERT_A);
    gpTomStartActivity();
    plugin.onMethodCall(
        new MethodCall("bindService", bindArgs(false, Collections.singletonList(FP_A))),
        mock(MethodChannel.Result.class));
    setzePaymentService();

    verkaufMitGpTomUi();

    Intent gestartet = shadowOf(app()).getNextStartedActivity();
    assertNotNull(gestartet);
    assertEquals(PROD, gestartet.getComponent().getPackageName());
  }

  @Test
  public void openGptomUI_nichtVertraut_startetGpTomNicht() throws Exception {
    installiereGpTom(PROD, ZERT_A);
    gpTomStartActivity();
    plugin.onMethodCall(
        new MethodCall("bindService", bindArgs(false, Collections.singletonList(FP_B))),
        mock(MethodChannel.Result.class));
    setzePaymentService();

    verkaufMitGpTomUi();

    assertNull(shadowOf(app()).getNextStartedActivity());
  }

  // ---------------------------------------------------------------------------
  // checkGpTomApp
  // ---------------------------------------------------------------------------

  @Test
  @SuppressWarnings("unchecked")
  public void checkGpTomApp_liefertMapMitFingerprintUndVersion() {
    installiereGpTom(PROD, ZERT_A);

    Map<String, Object> args = new HashMap<>();
    args.put("isDev", false);
    args.put("trustedSignatures", Collections.singletonList(FP_A));
    args.put("verifySignature", true);
    plugin.onMethodCall(new MethodCall("checkGpTomApp", args), result);
    idleMainLooper();

    ArgumentCaptor<Object> captor = ArgumentCaptor.forClass(Object.class);
    verify(result).success(captor.capture());
    Map<String, Object> map = (Map<String, Object>) captor.getValue();
    assertEquals(true, map.get("installed"));
    assertEquals(true, map.get("trusted"));
    assertEquals("pinned", map.get("source"));
    assertEquals(Collections.singletonList(FP_A), map.get("signatureSha256"));
    assertEquals("1.80.0", map.get("versionName"));
    assertEquals(180, map.get("versionCode"));
  }

  @Test
  @SuppressWarnings("unchecked")
  public void checkGpTomApp_devNichtInstalliert_notInstalled() {
    installiereGpTom(PROD, ZERT_A);

    Map<String, Object> args = new HashMap<>();
    args.put("isDev", true);
    plugin.onMethodCall(new MethodCall("checkGpTomApp", args), result);
    idleMainLooper();

    ArgumentCaptor<Object> captor = ArgumentCaptor.forClass(Object.class);
    verify(result).success(captor.capture());
    Map<String, Object> map = (Map<String, Object>) captor.getValue();
    assertEquals(false, map.get("installed"));
    assertEquals(false, map.get("trusted"));
    assertEquals("notInstalled", map.get("source"));
    assertEquals(Collections.emptyList(), map.get("signatureSha256"));
    assertNull(map.get("versionName"));
    assertNull(map.get("versionCode"));
    verify(result, never()).error(anyString(), anyString(), any());
  }
}
