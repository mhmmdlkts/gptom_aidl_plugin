package com.kreiseck.gptom_aidl_plugin;

import androidx.annotation.NonNull;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.content.pm.SigningInfo;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.RemoteException;
import android.util.Log;

import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.HashMap;
import java.util.Set;
import java.util.concurrent.Executor;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.Supplier;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

import com.google.gson.Gson;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

import cn.nexgo.smartconnect.IGPTomInfoChangedCallback;
import cn.nexgo.smartconnect.IGPTomInfoService;
import cn.nexgo.smartconnect.IGPTomLoginChangedCallback;
import cn.nexgo.smartconnect.IGPTomLoginService;
import cn.nexgo.smartconnect.ISmartconnectService;
import cn.nexgo.smartconnect.listener.IInquireResultListener;
import cn.nexgo.smartconnect.listener.IStateResultListener;
import cn.nexgo.smartconnect.listener.ITransactionRegisterListener;
import cn.nexgo.smartconnect.listener.ITransactionResultListener;
import cn.nexgo.smartconnect.model.ChangePasswordEntity;
import cn.nexgo.smartconnect.model.LoginEntity;

/**
 * GptomAidlPlugin
 *
 * Bindet die GPTom-Services (Payment, Login, Info) und reicht die
 * V2-JSON-Schnittstellen an Flutter durch. Über "isDev" kann je Verbindung
 * zwischen Dev- und Prod-Package gewählt werden. Vor jedem Bind und vor dem
 * Öffnen der GP-tom-Oberfläche wird die Signatur der App geprüft.
 *
 * Alle Binder-Aufrufe an GP tom sind synchron. Sie laufen deshalb nicht auf
 * dem Main-Thread, sondern auf zwei Executoren mit je einem Thread: einer für
 * den Payment-Service, einer für Login- und Info-Service. Ein hängendes
 * getGPTomInfo hält so keine Zahlung auf.
 */
public class GptomAidlPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {

  private static final String TAG = "GptomAidlPlugin";
  private static final String DEV_PACKAGE = "com.globalpayments.atom.dev";
  private static final String PROD_PACKAGE = "com.globalpayments.atom";
  private static final String PAYMENT_SERVICE_CLASS = "com.globalpayments.atom.data.external.api.NexgoAPIService";
  private static final String LOGIN_SERVICE_ACTION = "com.globalpayments.atom.BIND_TO_LOGIN_SERVICE";
  private static final String INFO_SERVICE_ACTION = "com.globalpayments.atom.BIND_TO_INFO_SERVICE";
  private static final long BIND_TIMEOUT_MS = 5000;
  /**
   * Frist, binnen der GP tom auf transactionRequestV2 antworten muss. Ohne
   * Wächter wartet die Kasse unbegrenzt, wenn die GP-tom-App weggewischt oder
   * vom System beendet wird. Der Wert ist großzügig: eine Kartenzahlung kann
   * mit Kartensuche und PIN-Eingabe über zwei Minuten dauern.
   * Über das Steuerfeld "timeoutMs" im Request-JSON überschreibbar.
   */
  private static final long DEFAULT_TRANSACTION_TIMEOUT_MS = 240000;
  /**
   * Frist für getGPTomInfo. GP tom fragt dafür zuerst sein Backend, offline
   * kann das lange dauern. Über das Argument "timeoutMs" überschreibbar.
   */
  private static final long DEFAULT_INFO_TIMEOUT_MS = 20000;
  /** Frist für transactionRegisterV2, über das Argument "timeoutMs" überschreibbar. */
  private static final long DEFAULT_REGISTER_TIMEOUT_MS = 30000;

  private static final String PAYMENT_NOT_BOUND = "GPTom Service not bound yet.";
  private static final String LOGIN_NOT_BOUND = "GPTom login service not bound yet.";
  private static final String INFO_NOT_BOUND = "GPTom info service not bound yet.";
  // Feste Fehlertexte im Login-Pfad: die Meldung einer Exception könnte
  // Zugangsdaten enthalten und geht deshalb weder an Dart noch ins Log.
  private static final String LOGIN_ERROR_TEXT = "Login-Aufruf an Genius Pay fehlgeschlagen.";
  private static final String LOGOUT_ERROR_TEXT = "Logout-Aufruf an Genius Pay fehlgeschlagen.";
  private static final String CHANGE_PASSWORD_ERROR_TEXT =
          "Passwortwechsel-Aufruf an Genius Pay fehlgeschlagen.";
  private static final String INFO_ERROR_TEXT = "Status-Abfrage an Genius Pay fehlgeschlagen.";
  private static final String UNTRUSTED_PAYMENT_TEXT =
          "Genius Pay nicht vertrauenswürdig – Zahlung nicht gestartet.";

  /** Gemerkte Fingerprints für das Erstvertrauen, Key = Paketname. */
  private static final String TRUST_PREFS = "gptom_aidl_plugin_trust";
  // Herkunft des Vertrauens, gleichlautend mit GptomTrustSource im Dart-Teil.
  private static final String SOURCE_PINNED = "pinned";
  private static final String SOURCE_FIRST_USE = "firstUse";
  private static final String SOURCE_MISMATCH = "mismatch";
  private static final String SOURCE_UNCHECKED = "unchecked";
  private static final String SOURCE_NOT_INSTALLED = "notInstalled";
  private static final char[] HEX = "0123456789ABCDEF".toCharArray();

  private MethodChannel channel;
  private Context applicationContext;
  private final Handler mainHandler = new Handler(Looper.getMainLooper());

  // Hintergrund-Threads für die Binder-Aufrufe, getrennt nach Payment und
  // Account (Login, Info). Werden beim Detach heruntergefahren.
  private Executor paymentExecutor;
  private Executor accountExecutor;

  // Gesetzt auf dem Main-Thread, gelesen in den Executoren.
  private volatile ISmartconnectService gptomService;
  private ServiceConnection serviceConnection;

  private volatile IGPTomLoginService loginService;
  private ServiceConnection loginServiceConnection;

  private volatile IGPTomInfoService infoService;
  private ServiceConnection infoServiceConnection;

  // isDev je Verbindung: ein Info-Bind auf das Dev-Paket darf die Zahlung
  // nicht auf eine andere App umlenken.
  private boolean paymentIsDev;
  private boolean loginIsDev;
  private boolean infoIsDev;
  // Paket, an das die bestehende Verbindung gebunden ist. Wechselt isDev,
  // wird die Verbindung neu aufgebaut.
  private String paymentConnectionPackage;
  private String loginConnectionPackage;
  private String infoConnectionPackage;
  // Wächter des zuletzt angestoßenen Binds je Verbindung. Wird die
  // Verbindung verworfen, beantwortet er den offenen Aufruf sofort mit false.
  // War der Aufruf schon beantwortet, ist er wirkungslos (SingleResult).
  private Runnable paymentBindWatchdog;
  private Runnable loginBindWatchdog;
  private Runnable infoBindWatchdog;
  // Prüfvorgaben (Pins, Prüfung an/aus) des letzten Payment-Binds.
  //
  // Bewusste Ausnahme von der Regel, dass die native Seite keine eigene
  // Sicherheitskonfiguration hält: requestTransactionV2 bekommt aus Dart
  // keine Prüfvorgaben mit, muss bei openGptomUI aber VOR dem Start der
  // Zahlung prüfen, ob die GP tom App noch vertrauenswürdig ist (eine
  // Zahlung, deren Oberfläche nicht geöffnet würde, darf gar nicht erst
  // laufen – sonst UNTRUSTED_APP), und in openGptomUi vor dem startActivity
  // noch einmal (App inzwischen getauscht). Dafür gelten die Vorgaben, mit
  // denen die Payment-Verbindung gebunden wurde. Jeder bindService
  // überschreibt sie; eine Änderung von GptomAidlPlugin.security wirkt hier
  // also erst ab dem nächsten bindService.
  private List<String> paymentPins = Collections.emptyList();
  private boolean paymentVerify = true;

  /** Ergebnis der Signaturprüfung der GP-tom-App. */
  static final class TrustResult {
    final boolean installed;
    final boolean trusted;
    /** pinned | firstUse | mismatch | unchecked | notInstalled */
    final String source;
    /** SHA-256 der aktuellen Signatur-Zertifikate, "AB:CD:…". */
    final List<String> signatureSha256;
    final String versionName;
    final Integer versionCode;

    TrustResult(boolean installed, boolean trusted, String source,
                List<String> signatureSha256, String versionName, Integer versionCode) {
      this.installed = installed;
      this.trusted = trusted;
      this.source = source;
      this.signatureSha256 = signatureSha256;
      this.versionName = versionName;
      this.versionCode = versionCode;
    }

    Map<String, Object> toMap() {
      Map<String, Object> map = new HashMap<>();
      map.put("installed", installed);
      map.put("trusted", trusted);
      map.put("source", source);
      map.put("signatureSha256", signatureSha256);
      map.put("versionName", versionName);
      map.put("versionCode", versionCode);
      return map;
    }
  }

  /**
   * Stellt sicher, dass ein MethodChannel.Result höchstens einmal und immer auf
   * dem Main-Thread beantwortet wird (AIDL-Callbacks kommen auf Binder-Threads).
   */
  private final class SingleResult {
    private final MethodChannel.Result result;
    private final AtomicBoolean answered = new AtomicBoolean(false);

    SingleResult(MethodChannel.Result result) {
      this.result = result;
    }

    /** @return true, wenn diese Antwort durchging (sonst war schon eine da). */
    boolean success(Object value) {
      if (answered.compareAndSet(false, true)) {
        mainHandler.post(() -> result.success(value));
        return true;
      }
      return false;
    }

    boolean error(String code, String message) {
      if (answered.compareAndSet(false, true)) {
        mainHandler.post(() -> result.error(code, message, null));
        return true;
      }
      return false;
    }

    /** true, wenn schon geantwortet wurde (z. B. vom Wächter). */
    boolean isAnswered() {
      return answered.get();
    }
  }

  /** Ein Binder-Aufruf an GP tom, ausgeführt mit dem dann aktuellen Service. */
  private interface BinderCall<S> {
    void run(S service) throws Exception;
  }

  /** Antwort auf eine Ausnahme aus einem Binder-Aufruf. */
  private interface ErrorAnswer {
    void answer(Exception e);
  }

  private final IGPTomLoginChangedCallback loginChangedCallback = new IGPTomLoginChangedCallback.Stub() {
    @Override
    public void onLoginStatusChanged(String status, String message) {
      mainHandler.post(() -> {
        if (channel != null) {
          Map<String, Object> args = new HashMap<>();
          args.put("status", status);
          args.put("message", message);
          channel.invokeMethod("onLoginStatusChanged", args);
        }
      });
    }
  };

  private final IGPTomInfoChangedCallback infoChangedCallback = new IGPTomInfoChangedCallback.Stub() {
    @Override
    public void onGPTomInfoChanged(String jsonData) {
      mainHandler.post(() -> {
        if (channel != null) {
          channel.invokeMethod("onGpTomInfoChanged", jsonData);
        }
      });
    }
  };

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding flutterPluginBinding) {
    this.applicationContext = flutterPluginBinding.getApplicationContext();
    if (paymentExecutor == null) {
      paymentExecutor = newWorker("gptom-payment");
    }
    if (accountExecutor == null) {
      accountExecutor = newWorker("gptom-account");
    }

    channel = new MethodChannel(
            flutterPluginBinding.getBinaryMessenger(),
            "gptom_aidl_plugin"
    );
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    if (channel != null) {
      channel.setMethodCallHandler(null);
      channel = null;
    }
    unbindPaymentService();
    unbindLoginService();
    unbindInfoService();
    // Schon eingereihte Aufgaben (z. B. unregisterCallback) laufen noch zu
    // Ende, neue werden abgelehnt.
    shutdown(paymentExecutor);
    shutdown(accountExecutor);
    paymentExecutor = null;
    accountExecutor = null;
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    switch (call.method) {
      case "existGpTomApp": {
        existGpTomApp(boolArgument(call, "isDev"), result);
        break;
      }
      case "checkGpTomApp": {
        result.success(verifyTarget(
                targetPackage(boolArgument(call, "isDev")),
                pinsArgument(call),
                verifyArgument(call)).toMap());
        break;
      }
      case "openGptomApp": {
        // Startbildschirm von Genius Pay öffnen (Knopf in der Kasse).
        String pkg = targetPackage(boolArgument(call, "isDev"));
        List<String> pins = pinsArgument(call);
        boolean verify = verifyArgument(call);
        runOnMain(() -> result.success(openGptomUi(pkg, pins, verify)));
        break;
      }
      case "resetTrustedSignature": {
        trustPrefs().edit().remove(targetPackage(boolArgument(call, "isDev"))).apply();
        result.success(true);
        break;
      }
      case "bindService": {
        paymentIsDev = boolArgument(call, "isDev");
        paymentPins = pinsArgument(call);
        paymentVerify = verifyArgument(call);
        bindPaymentService(paymentPins, paymentVerify, result);
        break;
      }
      case "unbindService": {
        unbindPaymentService();
        result.success(true);
        break;
      }
      case "registerTransactionV2": {
        String registerJson = call.argument("registerJson");
        registerTransactionV2(
                registerJson, timeoutArgument(call, DEFAULT_REGISTER_TIMEOUT_MS), result);
        break;
      }
      case "requestTransactionV2": {
        String requestJson = call.argument("requestJson");
        requestTransactionV2(requestJson, result);
        break;
      }
      case "stateRequest": {
        String transactionId = call.argument("transactionId");
        stateRequest(transactionId, result);
        break;
      }
      case "inquireTransaction": {
        String transactionId = call.argument("transactionId");
        inquireTransaction(transactionId, result);
        break;
      }
      case "bindLoginService": {
        loginIsDev = boolArgument(call, "isDev");
        bindLoginService(pinsArgument(call), verifyArgument(call), result);
        break;
      }
      case "unbindLoginService": {
        unbindLoginService();
        result.success(true);
        break;
      }
      case "gpTomLogin": {
        gpTomLogin(call, result);
        break;
      }
      case "gpTomLogout": {
        gpTomLogout(result);
        break;
      }
      case "gpTomChangePassword": {
        gpTomChangePassword(call, result);
        break;
      }
      case "bindInfoService": {
        infoIsDev = boolArgument(call, "isDev");
        bindInfoService(pinsArgument(call), verifyArgument(call), result);
        break;
      }
      case "unbindInfoService": {
        unbindInfoService();
        result.success(true);
        break;
      }
      case "getGpTomInfo": {
        getGpTomInfo(timeoutArgument(call, DEFAULT_INFO_TIMEOUT_MS), result);
        break;
      }
      default:
        result.notImplemented();
        break;
    }
  }

  private boolean boolArgument(MethodCall call, String key) {
    Boolean value = call.argument(key);
    return value != null && value;
  }

  /** Fingerprints aus Dart, dort schon normalisiert ("AB:CD:…"). Fehlt das Argument: keine. */
  private List<String> pinsArgument(MethodCall call) {
    Object value = call.argument("trustedSignatures");
    List<String> pins = new ArrayList<>();
    if (value instanceof List) {
      for (Object pin : (List<?>) value) {
        if (pin instanceof String) {
          pins.add((String) pin);
        }
      }
    }
    return pins;
  }

  /** Signaturprüfung an? Fehlt das Argument, wird geprüft. */
  private boolean verifyArgument(MethodCall call) {
    Boolean value = call.argument("verifySignature");
    return value == null || value;
  }

  /** Wächter-Frist aus dem Argument "timeoutMs". Werte <= 0 schalten ihn ab. */
  private long timeoutArgument(MethodCall call, long fallback) {
    Object value = call.argument("timeoutMs");
    return value instanceof Number ? ((Number) value).longValue() : fallback;
  }

  private String targetPackage(boolean dev) {
    return dev ? DEV_PACKAGE : PROD_PACKAGE;
  }

  /** Ersetzt die Hintergrund-Executoren (für Tests). */
  void setExecutorsForTesting(Executor payment, Executor account) {
    shutdown(paymentExecutor);
    shutdown(accountExecutor);
    paymentExecutor = payment;
    accountExecutor = account;
  }

  /** Paket der Payment-Verbindung (für Tests). */
  String paymentPackageForTesting() {
    return targetPackage(paymentIsDev);
  }

  // ---------------------------------------------------------------------------
  // HINTERGRUND-THREADS UND WÄCHTER
  // ---------------------------------------------------------------------------

  private static ExecutorService newWorker(String name) {
    return Executors.newSingleThreadExecutor(runnable -> {
      Thread thread = new Thread(runnable, name);
      thread.setDaemon(true);
      return thread;
    });
  }

  private static void shutdown(Executor executor) {
    if (executor instanceof ExecutorService) {
      ((ExecutorService) executor).shutdown();
    }
  }

  /** Reiht eine Aufgabe ein. false, wenn es den Executor nicht mehr gibt. */
  private static boolean runOn(Executor executor, Runnable task) {
    if (executor == null) {
      return false;
    }
    try {
      executor.execute(task);
      return true;
    } catch (RejectedExecutionException e) {
      return false;
    }
  }

  /** Führt die Aufgabe auf dem Main-Thread aus (sofort, wenn man schon dort ist). */
  private void runOnMain(Runnable task) {
    if (Looper.myLooper() == Looper.getMainLooper()) {
      task.run();
    } else {
      mainHandler.post(task);
    }
  }

  /**
   * Startet den Wächter für einen Aufruf: antwortet GP tom nicht binnen
   * timeoutMs, bekommt der Aufruf TIMEOUT. timeoutMs <= 0: kein Wächter.
   */
  private Runnable startWatchdog(SingleResult result, long timeoutMs) {
    Runnable watchdog = () -> result.error(
            "TIMEOUT",
            "Genius Pay hat binnen " + timeoutMs + " ms nicht geantwortet.");
    if (timeoutMs > 0) {
      mainHandler.postDelayed(watchdog, timeoutMs);
    }
    return watchdog;
  }

  private void cancelWatchdog(Runnable watchdog) {
    if (watchdog != null) {
      mainHandler.removeCallbacks(watchdog);
    }
  }

  /**
   * Führt einen Binder-Aufruf im Executor aus, mit dem Service, der dann
   * gebunden ist. Ist er bis dahin getrennt oder gibt es den Executor nicht
   * mehr, lautet die Antwort NOT_BOUND. Hat der Wächter schon geantwortet,
   * wird GP tom nicht mehr gefragt. Wirft der Aufruf, wird der Wächter
   * zurückgenommen und onError antwortet. Keine Ausnahme verlässt die Aufgabe.
   */
  private <S> void inBackground(Executor executor, Supplier<S> currentService,
                                SingleResult result, Runnable watchdog, String notBoundText,
                                BinderCall<S> call, ErrorAnswer onError) {
    Runnable task = () -> {
      if (result.isAnswered()) {
        return;
      }
      S service = currentService.get();
      if (service == null) {
        cancelWatchdog(watchdog);
        result.error("NOT_BOUND", notBoundText);
        return;
      }
      try {
        call.run(service);
      } catch (Exception e) {
        cancelWatchdog(watchdog);
        onError.answer(e);
      }
    };
    if (!runOn(executor, task)) {
      cancelWatchdog(watchdog);
      result.error("NOT_BOUND", notBoundText);
    }
  }

  private int bindFlags() {
    int flags = Context.BIND_AUTO_CREATE;
    if (Build.VERSION.SDK_INT >= 34) {
      // Ab Android 14 nötig, damit GPTom aus dem gebundenen Service heraus
      // seine UI starten darf.
      flags |= Context.BIND_ALLOW_ACTIVITY_STARTS;
    }
    return flags;
  }

  // ---------------------------------------------------------------------------
  // SIGNATURPRÜFUNG
  // ---------------------------------------------------------------------------

  /**
   * Prüft, ob die installierte GP-tom-App vertrauenswürdig ist.
   *
   * Mit Pins: vertraut, wenn ein Pin in der Signatur-Historie steht (deckt
   * Key-Rotation ab). Ohne Pins: Erstvertrauen, die erste Signatur wird je
   * Paket gemerkt und danach erzwungen. verify = false ist der Notschalter.
   */
  @SuppressWarnings("deprecation")
  TrustResult verifyTarget(String pkg, List<String> pins, boolean verify) {
    PackageInfo info;
    try {
      int flags = Build.VERSION.SDK_INT >= 28
              ? PackageManager.GET_SIGNING_CERTIFICATES
              : PackageManager.GET_SIGNATURES;
      info = applicationContext.getPackageManager().getPackageInfo(pkg, flags);
    } catch (PackageManager.NameNotFoundException e) {
      return new TrustResult(false, false, SOURCE_NOT_INSTALLED,
              Collections.<String>emptyList(), null, null);
    }

    Signature[] signer;
    Signature[] lineage;
    if (Build.VERSION.SDK_INT >= 28) {
      SigningInfo signing = info.signingInfo;
      if (signing == null) {
        signer = new Signature[0];
        lineage = signer;
      } else if (signing.hasMultipleSigners()) {
        // Mehrere Signer: dafür kennt Android keine Rotation.
        signer = nonNull(signing.getApkContentsSigners());
        lineage = signer;
      } else {
        // Historie inklusive aktuellem Zertifikat (zuletzt).
        lineage = nonNull(signing.getSigningCertificateHistory());
        signer = lineage.length == 0
                ? lineage
                : new Signature[] {lineage[lineage.length - 1]};
      }
    } else {
      signer = nonNull(info.signatures);
      lineage = signer;
    }

    List<String> signerFingerprints = fingerprints(signer);
    Set<String> lineageFingerprints = new HashSet<>(fingerprints(lineage));
    String versionName = info.versionName;
    Integer versionCode = info.versionCode;

    if (!verify) {
      return new TrustResult(true, true, SOURCE_UNCHECKED,
              signerFingerprints, versionName, versionCode);
    }

    if (pins != null && !pins.isEmpty()) {
      for (String pin : pins) {
        if (lineageFingerprints.contains(pin)) {
          return new TrustResult(true, true, SOURCE_PINNED,
                  signerFingerprints, versionName, versionCode);
        }
      }
      return new TrustResult(true, false, SOURCE_MISMATCH,
              signerFingerprints, versionName, versionCode);
    }

    // Erstvertrauen (trust on first use)
    SharedPreferences prefs = trustPrefs();
    String stored = prefs.getString(pkg, null);
    if (stored == null) {
      if (signerFingerprints.isEmpty()) {
        // Ohne Signatur gibt es nichts zu merken – nie vertrauen.
        return new TrustResult(true, false, SOURCE_MISMATCH,
                signerFingerprints, versionName, versionCode);
      }
      List<String> sorted = new ArrayList<>(signerFingerprints);
      Collections.sort(sorted);
      prefs.edit().putString(pkg, String.join(",", sorted)).apply();
      return new TrustResult(true, true, SOURCE_FIRST_USE,
              signerFingerprints, versionName, versionCode);
    }
    boolean trusted = lineageFingerprints.containsAll(Arrays.asList(stored.split(",")));
    return new TrustResult(true, trusted, trusted ? SOURCE_FIRST_USE : SOURCE_MISMATCH,
            signerFingerprints, versionName, versionCode);
  }

  /**
   * Signaturprüfung vor einem Bind. Abgelehnt wird mit festem Text im Log,
   * ohne Fingerprints.
   */
  private boolean trustedForBind(String pkg, List<String> pins, boolean verify) {
    TrustResult trust = verifyTarget(pkg, pins, verify);
    if (!trust.trusted) {
      Log.w(TAG, "Bindung an " + pkg + " abgelehnt: " + trust.source);
    }
    return trust.trusted;
  }

  private SharedPreferences trustPrefs() {
    return applicationContext.getSharedPreferences(TRUST_PREFS, Context.MODE_PRIVATE);
  }

  private static Signature[] nonNull(Signature[] signatures) {
    return signatures != null ? signatures : new Signature[0];
  }

  private static List<String> fingerprints(Signature[] signatures) {
    List<String> list = new ArrayList<>(signatures.length);
    for (Signature signature : signatures) {
      list.add(fingerprint(signature));
    }
    return list;
  }

  /** SHA-256 über das Zertifikat, Großbuchstaben mit Doppelpunkten. */
  private static String fingerprint(Signature signature) {
    byte[] hash;
    try {
      hash = MessageDigest.getInstance("SHA-256").digest(signature.toByteArray());
    } catch (NoSuchAlgorithmException e) {
      // SHA-256 gehört zum Pflichtumfang jeder Java-/Android-Laufzeit.
      throw new IllegalStateException(e);
    }
    StringBuilder text = new StringBuilder(hash.length * 3);
    for (byte b : hash) {
      if (text.length() > 0) {
        text.append(':');
      }
      text.append(HEX[(b >> 4) & 0xF]).append(HEX[b & 0xF]);
    }
    return text.toString();
  }

  private void existGpTomApp(boolean checkDev, MethodChannel.Result result) {
    String packageName = checkDev ? DEV_PACKAGE : PROD_PACKAGE;
    try {
      applicationContext.getPackageManager().getApplicationInfo(packageName, 0);
      result.success(true);
    } catch (Exception e) {
      // NameNotFoundException -> nicht installiert
      result.success(false);
    }
  }

  /**
   * Beantwortet einen noch offenen Bind sofort mit false, weil seine
   * Verbindung verworfen wird. War er schon beantwortet, passiert nichts.
   */
  private void answerPendingBind(Runnable bindWatchdog) {
    if (bindWatchdog != null) {
      mainHandler.removeCallbacks(bindWatchdog);
      bindWatchdog.run();
    }
  }

  // ---------------------------------------------------------------------------
  // PAYMENT SERVICE (ISmartconnectService)
  // ---------------------------------------------------------------------------
  private void bindPaymentService(List<String> pins, boolean verify, MethodChannel.Result rawResult) {
    final SingleResult result = new SingleResult(rawResult);
    String pkg = targetPackage(paymentIsDev);
    if (serviceConnection != null && !pkg.equals(paymentConnectionPackage)) {
      // isDev gewechselt: alte Verbindung zuerst trennen, dann normal binden.
      unbindPaymentService();
    }
    if (!trustedForBind(pkg, pins, verify)) {
      // Nach einem "false" darf auch eine bestehende Verbindung nicht weiter
      // für Zahlungen genutzt werden.
      unbindPaymentService();
      result.success(false);
      return;
    }
    if (gptomService != null) {
      result.success(true);
      return;
    }

    try {
      Intent intent = new Intent();
      intent.setComponent(new ComponentName(pkg, PAYMENT_SERVICE_CLASS));

      // Hängende oder getrennte alte Verbindung verwerfen.
      unbindPaymentService();

      // bindService() liefert nur "Anfrage angenommen" – verbunden sind wir
      // erst bei onServiceConnected. Falls die Verbindung nie zustande kommt,
      // nicht ewig hängen lassen. Der Wächter antwortet immer für genau diesen
      // Aufruf; nach onServiceConnected ist er entfernt bzw. wirkungslos.
      final Runnable bindWatchdog = () -> result.success(false);

      paymentConnectionPackage = pkg;
      serviceConnection = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, IBinder service) {
          gptomService = ISmartconnectService.Stub.asInterface(service);
          mainHandler.removeCallbacks(bindWatchdog);
          result.success(true);
        }

        @Override
        public void onServiceDisconnected(ComponentName name) {
          gptomService = null;
        }

        @Override
        public void onBindingDied(ComponentName name) {
          gptomService = null;
        }
      };

      boolean bound = applicationContext.bindService(intent, serviceConnection, bindFlags());
      if (!bound) {
        try {
          applicationContext.unbindService(serviceConnection);
        } catch (Exception ignored) {
        }
        serviceConnection = null;
        result.success(false);
        return;
      }

      paymentBindWatchdog = bindWatchdog;
      mainHandler.postDelayed(bindWatchdog, BIND_TIMEOUT_MS);
    } catch (Exception e) {
      result.error("BIND_ERROR", e.getMessage());
    }
  }

  private void unbindPaymentService() {
    answerPendingBind(paymentBindWatchdog);
    paymentBindWatchdog = null;
    if (serviceConnection != null) {
      try {
        applicationContext.unbindService(serviceConnection);
      } catch (Exception e) {
        Log.e(TAG, "unbindPaymentService: " + e.getMessage());
      }
      serviceConnection = null;
      gptomService = null;
      paymentConnectionPackage = null;
    }
  }

  // ---------------------------------------------------------------------------
  // 1) registerTransactionV2
  // ---------------------------------------------------------------------------
  private void registerTransactionV2(String registerJson, long timeoutMs,
                                     MethodChannel.Result rawResult) {
    final SingleResult result = new SingleResult(rawResult);
    if (gptomService == null) {
      result.error("NOT_BOUND", PAYMENT_NOT_BOUND);
      return;
    }
    final Runnable watchdog = startWatchdog(result, timeoutMs);
    inBackground(paymentExecutor, () -> gptomService, result, watchdog, PAYMENT_NOT_BOUND,
            service -> service.transactionRegisterV2(registerJson,
                    new ITransactionRegisterListener.Stub() {
                      @Override
                      public void onRegisterV2Result(String resultJson) {
                        cancelWatchdog(watchdog);
                        // Nach TIMEOUT verworfen: eine Registrierung allein
                        // startet keine Zahlung.
                        result.success(resultJson);
                      }

                      @Override
                      public void onRegisterResult(
                              cn.nexgo.smartconnect.model.RegisterResultEntity registerResultEntity) {
                        // V1, deprecated
                      }
                    }),
            e -> result.error("REMOTE_EXCEPTION", e.getMessage()));
  }

  // ---------------------------------------------------------------------------
  // 2) requestTransactionV2
  // ---------------------------------------------------------------------------
  private void requestTransactionV2(String requestJson, MethodChannel.Result rawResult) {
    final SingleResult result = new SingleResult(rawResult);
    if (gptomService == null) {
      result.error("NOT_BOUND", PAYMENT_NOT_BOUND);
      return;
    }
    final String finalJson;
    final boolean openGptomUI;
    final long timeoutMs;
    try {
      // JsonObject statt Map, damit Ganzzahlen (amount etc.) beim erneuten
      // Serialisieren nicht als "1111.0" enden.
      JsonObject parsed = JsonParser.parseString(requestJson).getAsJsonObject();

      openGptomUI = parsed.has("openGptomUI")
              && !parsed.get("openGptomUI").isJsonNull()
              && parsed.get("openGptomUI").getAsBoolean();

      long timeout = DEFAULT_TRANSACTION_TIMEOUT_MS;
      if (parsed.has("timeoutMs") && !parsed.get("timeoutMs").isJsonNull()) {
        try {
          timeout = parsed.get("timeoutMs").getAsLong();
        } catch (Exception ignored) {
          // unbrauchbarer Wert -> Standardfrist
        }
      }
      timeoutMs = timeout;

      // Steuerfelder gehören nicht ins GPTom-Request-JSON
      parsed.remove("redirect");
      parsed.remove("openGptomUI");
      parsed.remove("timeoutMs");

      finalJson = parsed.toString();
    } catch (Exception e) {
      result.error("INVALID_REQUEST", e.getMessage());
      return;
    }

    final String paymentPackage = targetPackage(paymentIsDev);
    if (openGptomUI && !verifyTarget(paymentPackage, paymentPins, paymentVerify).trusted) {
      // Vor dem Start prüfen: eine Zahlung in einer App, deren Oberfläche
      // nicht geöffnet würde, darf gar nicht erst laufen.
      Log.w(TAG, "GP tom nicht vertrauenswürdig – Zahlung nicht gestartet");
      result.error("UNTRUSTED_APP", UNTRUSTED_PAYMENT_TEXT);
      return;
    }

    // Wächter: Antwortet GP tom nicht, darf die Kasse nicht ewig hängen. Er
    // läuft ab dem Aufruf, also auch, solange der Payment-Executor belegt ist.
    // Läuft er ab, bevor die Aufgabe dran ist, wird keine Zahlung gestartet.
    final Runnable timeoutWatchdog = startWatchdog(result, timeoutMs);

    inBackground(paymentExecutor, () -> gptomService, result, timeoutWatchdog, PAYMENT_NOT_BOUND,
            service -> {
              service.transactionRequestV2(finalJson, new ITransactionResultListener.Stub() {
                @Override
                public void onTransactionV2Result(String resultJson) {
                  cancelWatchdog(timeoutWatchdog);
                  if (!result.success(resultJson)) {
                    // Der Wächter hat bereits mit TIMEOUT geantwortet. Der Kanal darf
                    // nicht doppelt beantwortet werden – das echte Ergebnis geht als
                    // Ereignis an Dart, damit die App einen unklaren Ausgang
                    // nachträglich auflösen kann.
                    sendLateTransactionResult(resultJson);
                  }
                }

                @Override
                public void onTransactionResult(
                  cn.nexgo.smartconnect.model.TransactionResultEntity transactionResultEntity
                ) {
                  // V1, deprecated
                }
              });
              if (openGptomUI) {
                runOnMain(() -> openGptomUi(paymentPackage, paymentPins, paymentVerify));
              }
            },
            e -> result.error(
                    e instanceof RemoteException ? "REMOTE_EXCEPTION" : "INVALID_REQUEST",
                    e.getMessage()));
  }

  /**
   * Holt GP tom nach vorn (Main-Thread). Die Signatur wird noch einmal
   * geprüft, falls die App inzwischen getauscht wurde. Fehler hier ändern
   * nichts an der laufenden Zahlung und werden nur protokolliert.
   * Gibt zurück, ob der Start ans System übergeben wurde.
   */
  private boolean openGptomUi(String paymentPackage, List<String> pins, boolean verify) {
    try {
      if (!verifyTarget(paymentPackage, pins, verify).trusted) {
        Log.w(TAG, "GP tom nicht vertrauenswürdig – UI nicht geöffnet");
        return false;
      }
      Intent openGptom = applicationContext.getPackageManager()
              .getLaunchIntentForPackage(paymentPackage);
      if (openGptom != null) {
        openGptom.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        applicationContext.startActivity(openGptom);
        return true;
      }
      Log.e(TAG, "openGptomUi: kein Start-Intent");
      return false;
    } catch (Exception e) {
      Log.e(TAG, "openGptomUi: GP tom konnte nicht geöffnet werden");
      return false;
    }
  }

  /**
   * Reicht ein Ergebnis nach, das erst nach dem Wächter-Timeout eintraf.
   * Kein Log: Transaktions- und Belegdaten gehören nicht ins Protokoll.
   */
  private void sendLateTransactionResult(String resultJson) {
    mainHandler.post(() -> {
      if (channel != null) {
        channel.invokeMethod("onLateTransactionResult", resultJson);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // 3) stateRequest
  // ---------------------------------------------------------------------------
  private void stateRequest(String transactionId, MethodChannel.Result rawResult) {
    final SingleResult result = new SingleResult(rawResult);
    if (gptomService == null) {
      result.error("NOT_BOUND", PAYMENT_NOT_BOUND);
      return;
    }
    inBackground(paymentExecutor, () -> gptomService, result, null, PAYMENT_NOT_BOUND,
            service -> service.stateRequest(transactionId, new IStateResultListener.Stub() {
              @Override
              public void onStateResult(String resultJson) {
                result.success(resultJson);
              }
            }),
            e -> result.error("REMOTE_EXCEPTION", e.getMessage()));
  }

  // ---------------------------------------------------------------------------
  // 4) inquireTransaction
  // ---------------------------------------------------------------------------
  private void inquireTransaction(String transactionId, MethodChannel.Result rawResult) {
    final SingleResult result = new SingleResult(rawResult);
    if (gptomService == null) {
      result.error("NOT_BOUND", PAYMENT_NOT_BOUND);
      return;
    }
    inBackground(paymentExecutor, () -> gptomService, result, null, PAYMENT_NOT_BOUND,
            service -> service.TransactionInquire(transactionId, new IInquireResultListener.Stub() {
              @Override
              public void onInquireResult(
                      cn.nexgo.smartconnect.model.InquireResultEntity inquireResultEntity) {
                result.success(new Gson().toJson(inquireResultEntity));
              }
            }),
            e -> result.error("REMOTE_EXCEPTION", e.getMessage()));
  }

  // ---------------------------------------------------------------------------
  // LOGIN SERVICE (IGPTomLoginService, ab AIDL 1.29.0)
  // ---------------------------------------------------------------------------
  private void bindLoginService(List<String> pins, boolean verify, MethodChannel.Result rawResult) {
    final SingleResult result = new SingleResult(rawResult);
    String pkg = targetPackage(loginIsDev);
    if (loginServiceConnection != null && !pkg.equals(loginConnectionPackage)) {
      unbindLoginService();
    }
    if (!trustedForBind(pkg, pins, verify)) {
      unbindLoginService();
      result.success(false);
      return;
    }
    if (loginService != null) {
      result.success(true);
      return;
    }

    try {
      Intent intent = new Intent(LOGIN_SERVICE_ACTION);
      intent.setPackage(pkg);

      if (applicationContext.getPackageManager().queryIntentServices(intent, 0).isEmpty()) {
        result.success(false);
        return;
      }

      // Hängende oder getrennte alte Verbindung verwerfen.
      unbindLoginService();

      final Runnable bindWatchdog = () -> result.success(false);

      loginConnectionPackage = pkg;
      loginServiceConnection = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, IBinder binder) {
          final IGPTomLoginService service = IGPTomLoginService.Stub.asInterface(binder);
          loginService = service;
          mainHandler.removeCallbacks(bindWatchdog);
          if (service != null) {
            // Synchroner Binder-Aufruf, also im Account-Executor. Der arbeitet
            // der Reihe nach: ein folgendes Login läuft erst danach.
            runOn(accountExecutor, () -> {
              try {
                service.registerCallback(loginChangedCallback);
              } catch (Exception e) {
                Log.e(TAG, "bindLoginService: registerCallback fehlgeschlagen");
              }
            });
          }
          result.success(true);
        }

        @Override
        public void onServiceDisconnected(ComponentName name) {
          loginService = null;
        }

        @Override
        public void onBindingDied(ComponentName name) {
          loginService = null;
        }
      };

      boolean bound = applicationContext.bindService(intent, loginServiceConnection, Context.BIND_AUTO_CREATE);
      if (!bound) {
        try {
          applicationContext.unbindService(loginServiceConnection);
        } catch (Exception ignored) {
        }
        loginServiceConnection = null;
        result.success(false);
        return;
      }

      loginBindWatchdog = bindWatchdog;
      mainHandler.postDelayed(bindWatchdog, BIND_TIMEOUT_MS);
    } catch (Exception e) {
      result.error("BIND_ERROR", e.getMessage());
    }
  }

  private void unbindLoginService() {
    answerPendingBind(loginBindWatchdog);
    loginBindWatchdog = null;
    if (loginServiceConnection != null) {
      final IGPTomLoginService service = loginService;
      if (service != null) {
        // Abmelden ist ein Binder-Aufruf und darf den Main-Thread nicht blockieren.
        runOn(accountExecutor, () -> {
          try {
            service.unregisterCallback(loginChangedCallback);
          } catch (Exception ignored) {
          }
        });
      }
      try {
        applicationContext.unbindService(loginServiceConnection);
      } catch (Exception e) {
        Log.e(TAG, "unbindLoginService: Trennen fehlgeschlagen");
      }
      loginServiceConnection = null;
      loginService = null;
      loginConnectionPackage = null;
    }
  }

  // Login, Logout und Passwortwechsel: Die Antwort heißt nur "angenommen",
  // das Ergebnis kommt asynchron über onLoginStatusChanged. Fehler werden mit
  // festem Text gemeldet, nie mit der Meldung der Exception.

  private void gpTomLogin(MethodCall call, MethodChannel.Result rawResult) {
    final SingleResult result = new SingleResult(rawResult);
    if (loginService == null) {
      result.error("NOT_BOUND", LOGIN_NOT_BOUND);
      return;
    }
    inBackground(accountExecutor, () -> loginService, result, null, LOGIN_NOT_BOUND,
            service -> {
              LoginEntity entity = new LoginEntity(
                      call.argument("username"),
                      call.argument("password"),
                      call.argument("terminalId"),
                      call.argument("authCode")
              );
              service.login(new Gson().toJson(entity));
              result.success(true);
            },
            e -> result.error("LOGIN_ERROR", LOGIN_ERROR_TEXT));
  }

  private void gpTomLogout(MethodChannel.Result rawResult) {
    final SingleResult result = new SingleResult(rawResult);
    if (loginService == null) {
      result.error("NOT_BOUND", LOGIN_NOT_BOUND);
      return;
    }
    inBackground(accountExecutor, () -> loginService, result, null, LOGIN_NOT_BOUND,
            service -> {
              service.logout();
              result.success(true);
            },
            e -> result.error("LOGOUT_ERROR", LOGOUT_ERROR_TEXT));
  }

  private void gpTomChangePassword(MethodCall call, MethodChannel.Result rawResult) {
    final SingleResult result = new SingleResult(rawResult);
    if (loginService == null) {
      result.error("NOT_BOUND", LOGIN_NOT_BOUND);
      return;
    }
    inBackground(accountExecutor, () -> loginService, result, null, LOGIN_NOT_BOUND,
            service -> {
              Boolean validationOnly = call.argument("validationOnly");
              ChangePasswordEntity entity = new ChangePasswordEntity(
                      call.argument("oldPass"),
                      call.argument("newPass"),
                      call.argument("authCode"),
                      validationOnly != null && validationOnly
              );
              service.changePassword(new Gson().toJson(entity));
              result.success(true);
            },
            e -> result.error("CHANGE_PASSWORD_ERROR", CHANGE_PASSWORD_ERROR_TEXT));
  }

  // ---------------------------------------------------------------------------
  // INFO SERVICE (IGPTomInfoService)
  // ---------------------------------------------------------------------------
  private void bindInfoService(List<String> pins, boolean verify, MethodChannel.Result rawResult) {
    final SingleResult result = new SingleResult(rawResult);
    String pkg = targetPackage(infoIsDev);
    if (infoServiceConnection != null && !pkg.equals(infoConnectionPackage)) {
      unbindInfoService();
    }
    if (!trustedForBind(pkg, pins, verify)) {
      unbindInfoService();
      result.success(false);
      return;
    }
    if (infoService != null) {
      result.success(true);
      return;
    }

    try {
      Intent intent = new Intent(INFO_SERVICE_ACTION);
      intent.setPackage(pkg);

      if (applicationContext.getPackageManager().queryIntentServices(intent, 0).isEmpty()) {
        result.success(false);
        return;
      }

      // Hängende oder getrennte alte Verbindung verwerfen.
      unbindInfoService();

      final Runnable bindWatchdog = () -> result.success(false);

      infoConnectionPackage = pkg;
      infoServiceConnection = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, IBinder binder) {
          final IGPTomInfoService service = IGPTomInfoService.Stub.asInterface(binder);
          infoService = service;
          mainHandler.removeCallbacks(bindWatchdog);
          if (service != null) {
            runOn(accountExecutor, () -> {
              try {
                service.registerCallback(infoChangedCallback);
              } catch (Exception e) {
                Log.e(TAG, "bindInfoService: registerCallback fehlgeschlagen");
              }
            });
          }
          result.success(true);
        }

        @Override
        public void onServiceDisconnected(ComponentName name) {
          infoService = null;
        }

        @Override
        public void onBindingDied(ComponentName name) {
          infoService = null;
        }
      };

      boolean bound = applicationContext.bindService(intent, infoServiceConnection, Context.BIND_AUTO_CREATE);
      if (!bound) {
        try {
          applicationContext.unbindService(infoServiceConnection);
        } catch (Exception ignored) {
        }
        infoServiceConnection = null;
        result.success(false);
        return;
      }

      infoBindWatchdog = bindWatchdog;
      mainHandler.postDelayed(bindWatchdog, BIND_TIMEOUT_MS);
    } catch (Exception e) {
      result.error("BIND_ERROR", e.getMessage());
    }
  }

  private void unbindInfoService() {
    answerPendingBind(infoBindWatchdog);
    infoBindWatchdog = null;
    if (infoServiceConnection != null) {
      final IGPTomInfoService service = infoService;
      if (service != null) {
        runOn(accountExecutor, () -> {
          try {
            service.unregisterCallback(infoChangedCallback);
          } catch (Exception ignored) {
          }
        });
      }
      try {
        applicationContext.unbindService(infoServiceConnection);
      } catch (Exception e) {
        Log.e(TAG, "unbindInfoService: Trennen fehlgeschlagen");
      }
      infoServiceConnection = null;
      infoService = null;
      infoConnectionPackage = null;
    }
  }

  private void getGpTomInfo(long timeoutMs, MethodChannel.Result rawResult) {
    final SingleResult result = new SingleResult(rawResult);
    if (infoService == null) {
      result.error("NOT_BOUND", INFO_NOT_BOUND);
      return;
    }
    // Ohne Netz kann GP tom hier lange hängen. Der Wächter beantwortet den
    // Aufruf, der Binder-Aufruf selbst läuft im Account-Executor weiter.
    final Runnable watchdog = startWatchdog(result, timeoutMs);
    inBackground(accountExecutor, () -> infoService, result, watchdog, INFO_NOT_BOUND,
            service -> {
              String json = service.getGPTomInfo();
              cancelWatchdog(watchdog);
              result.success(json);
            },
            e -> result.error("INFO_ERROR", INFO_ERROR_TEXT));
  }
}
