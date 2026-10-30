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
import java.util.concurrent.atomic.AtomicBoolean;

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

  private ISmartconnectService gptomService;
  private ServiceConnection serviceConnection;

  private IGPTomLoginService loginService;
  private ServiceConnection loginServiceConnection;

  private IGPTomInfoService infoService;
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
  // Prüfvorgaben des letzten Payment-Binds, gebraucht vor openGptomUI.
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
        registerTransactionV2(registerJson, result);
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
        getGpTomInfo(result);
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

  private String targetPackage(boolean dev) {
    return dev ? DEV_PACKAGE : PROD_PACKAGE;
  }

  /** Paket der Payment-Verbindung (für Tests). */
  String paymentPackageForTesting() {
    return targetPackage(paymentIsDev);
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

      if (serviceConnection != null) {
        try {
          applicationContext.unbindService(serviceConnection);
        } catch (Exception ignored) {
        }
        serviceConnection = null;
      }

      // bindService() liefert nur "Anfrage angenommen" – verbunden sind wir
      // erst bei onServiceConnected. Falls die Verbindung nie zustande kommt,
      // nicht ewig hängen lassen.
      final Runnable bindWatchdog = () -> {
        if (gptomService == null) {
          result.success(false);
        }
      };

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

      mainHandler.postDelayed(bindWatchdog, BIND_TIMEOUT_MS);
    } catch (Exception e) {
      result.error("BIND_ERROR", e.getMessage());
    }
  }

  private void unbindPaymentService() {
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
  private void registerTransactionV2(String registerJson, MethodChannel.Result rawResult) {
    final SingleResult result = new SingleResult(rawResult);
    if (gptomService == null) {
      result.error("NOT_BOUND", "GPTom Service not bound yet.");
      return;
    }
    try {
      gptomService.transactionRegisterV2(registerJson, new ITransactionRegisterListener.Stub() {
        @Override
        public void onRegisterV2Result(String resultJson) {
          result.success(resultJson);
        }

        @Override
        public void onRegisterResult(cn.nexgo.smartconnect.model.RegisterResultEntity registerResultEntity) {
          // V1, deprecated
        }
      });
    } catch (RemoteException e) {
      result.error("REMOTE_EXCEPTION", e.getMessage());
    }
  }

  // ---------------------------------------------------------------------------
  // 2) requestTransactionV2
  // ---------------------------------------------------------------------------
  private void requestTransactionV2(String requestJson, MethodChannel.Result rawResult) {
    final SingleResult result = new SingleResult(rawResult);
    if (gptomService == null) {
      result.error("NOT_BOUND", "GPTom Service not bound yet.");
      return;
    }
    try {
      // JsonObject statt Map, damit Ganzzahlen (amount etc.) beim erneuten
      // Serialisieren nicht als "1111.0" enden.
      JsonObject parsed = JsonParser.parseString(requestJson).getAsJsonObject();

      boolean openGptomUI = parsed.has("openGptomUI")
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
      final long timeoutMs = timeout;

      // Steuerfelder gehören nicht ins GPTom-Request-JSON
      parsed.remove("redirect");
      parsed.remove("openGptomUI");
      parsed.remove("timeoutMs");

      String finalJson = parsed.toString();

      // Wächter: Antwortet GP tom nicht, darf die Kasse nicht ewig hängen.
      final Runnable timeoutWatchdog = () -> result.error(
              "TIMEOUT",
              "GP tom hat binnen " + timeoutMs + " ms nicht geantwortet.");

      gptomService.transactionRequestV2(finalJson, new ITransactionResultListener.Stub() {
        @Override
        public void onTransactionV2Result(String resultJson) {
          mainHandler.removeCallbacks(timeoutWatchdog);
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

      if (timeoutMs > 0) {
        mainHandler.postDelayed(timeoutWatchdog, timeoutMs);
      }

      if (openGptomUI) {
        String paymentPackage = targetPackage(paymentIsDev);
        if (!verifyTarget(paymentPackage, paymentPins, paymentVerify).trusted) {
          Log.w(TAG, "GP tom nicht vertrauenswürdig – UI nicht geöffnet");
        } else {
          Intent openGptom = applicationContext.getPackageManager()
                  .getLaunchIntentForPackage(paymentPackage);
          if (openGptom != null) {
            openGptom.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            applicationContext.startActivity(openGptom);
          } else {
            Log.e(TAG, "requestTransactionV2: GPTom app not found!");
          }
        }
      }
    } catch (RemoteException e) {
      result.error("REMOTE_EXCEPTION", e.getMessage());
    } catch (Exception e) {
      result.error("INVALID_REQUEST", e.getMessage());
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
      result.error("NOT_BOUND", "GPTom Service not bound yet.");
      return;
    }
    try {
      gptomService.stateRequest(transactionId, new IStateResultListener.Stub() {
        @Override
        public void onStateResult(String resultJson) {
          result.success(resultJson);
        }
      });
    } catch (RemoteException e) {
      result.error("REMOTE_EXCEPTION", e.getMessage());
    }
  }

  // ---------------------------------------------------------------------------
  // 4) inquireTransaction
  // ---------------------------------------------------------------------------
  private void inquireTransaction(String transactionId, MethodChannel.Result rawResult) {
    final SingleResult result = new SingleResult(rawResult);
    if (gptomService == null) {
      result.error("NOT_BOUND", "GPTom Service not bound yet.");
      return;
    }
    try {
      gptomService.TransactionInquire(transactionId, new IInquireResultListener.Stub() {
        @Override
        public void onInquireResult(cn.nexgo.smartconnect.model.InquireResultEntity inquireResultEntity) {
          result.success(new Gson().toJson(inquireResultEntity));
        }
      });
    } catch (RemoteException e) {
      result.error("REMOTE_EXCEPTION", e.getMessage());
    }
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

      if (loginServiceConnection != null) {
        try {
          applicationContext.unbindService(loginServiceConnection);
        } catch (Exception ignored) {
        }
        loginServiceConnection = null;
      }

      final Runnable bindWatchdog = () -> {
        if (loginService == null) {
          result.success(false);
        }
      };

      loginConnectionPackage = pkg;
      loginServiceConnection = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, IBinder binder) {
          loginService = IGPTomLoginService.Stub.asInterface(binder);
          mainHandler.removeCallbacks(bindWatchdog);
          try {
            loginService.registerCallback(loginChangedCallback);
          } catch (RemoteException e) {
            Log.e(TAG, "bindLoginService: registerCallback failed: " + e.getMessage());
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

      mainHandler.postDelayed(bindWatchdog, BIND_TIMEOUT_MS);
    } catch (Exception e) {
      result.error("BIND_ERROR", e.getMessage());
    }
  }

  private void unbindLoginService() {
    if (loginServiceConnection != null) {
      try {
        if (loginService != null) {
          loginService.unregisterCallback(loginChangedCallback);
        }
      } catch (Exception ignored) {
      }
      try {
        applicationContext.unbindService(loginServiceConnection);
      } catch (Exception e) {
        Log.e(TAG, "unbindLoginService: " + e.getMessage());
      }
      loginServiceConnection = null;
      loginService = null;
      loginConnectionPackage = null;
    }
  }

  private void gpTomLogin(MethodCall call, MethodChannel.Result rawResult) {
    final SingleResult result = new SingleResult(rawResult);
    if (loginService == null) {
      result.error("NOT_BOUND", "GPTom login service not bound yet.");
      return;
    }
    try {
      LoginEntity entity = new LoginEntity(
              call.argument("username"),
              call.argument("password"),
              call.argument("terminalId"),
              call.argument("authCode")
      );
      loginService.login(new Gson().toJson(entity));
      // Das Ergebnis kommt asynchron über onLoginStatusChanged.
      result.success(true);
    } catch (Exception e) {
      result.error("LOGIN_ERROR", e.getMessage());
    }
  }

  private void gpTomLogout(MethodChannel.Result rawResult) {
    final SingleResult result = new SingleResult(rawResult);
    if (loginService == null) {
      result.error("NOT_BOUND", "GPTom login service not bound yet.");
      return;
    }
    try {
      loginService.logout();
      result.success(true);
    } catch (Exception e) {
      result.error("LOGOUT_ERROR", e.getMessage());
    }
  }

  private void gpTomChangePassword(MethodCall call, MethodChannel.Result rawResult) {
    final SingleResult result = new SingleResult(rawResult);
    if (loginService == null) {
      result.error("NOT_BOUND", "GPTom login service not bound yet.");
      return;
    }
    try {
      Boolean validationOnly = call.argument("validationOnly");
      ChangePasswordEntity entity = new ChangePasswordEntity(
              call.argument("oldPass"),
              call.argument("newPass"),
              call.argument("authCode"),
              validationOnly != null && validationOnly
      );
      loginService.changePassword(new Gson().toJson(entity));
      // Das Ergebnis kommt asynchron über onLoginStatusChanged.
      result.success(true);
    } catch (Exception e) {
      result.error("CHANGE_PASSWORD_ERROR", e.getMessage());
    }
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

      if (infoServiceConnection != null) {
        try {
          applicationContext.unbindService(infoServiceConnection);
        } catch (Exception ignored) {
        }
        infoServiceConnection = null;
      }

      final Runnable bindWatchdog = () -> {
        if (infoService == null) {
          result.success(false);
        }
      };

      infoConnectionPackage = pkg;
      infoServiceConnection = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, IBinder binder) {
          infoService = IGPTomInfoService.Stub.asInterface(binder);
          mainHandler.removeCallbacks(bindWatchdog);
          try {
            infoService.registerCallback(infoChangedCallback);
          } catch (RemoteException e) {
            Log.e(TAG, "bindInfoService: registerCallback failed: " + e.getMessage());
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

      mainHandler.postDelayed(bindWatchdog, BIND_TIMEOUT_MS);
    } catch (Exception e) {
      result.error("BIND_ERROR", e.getMessage());
    }
  }

  private void unbindInfoService() {
    if (infoServiceConnection != null) {
      try {
        if (infoService != null) {
          infoService.unregisterCallback(infoChangedCallback);
        }
      } catch (Exception ignored) {
      }
      try {
        applicationContext.unbindService(infoServiceConnection);
      } catch (Exception e) {
        Log.e(TAG, "unbindInfoService: " + e.getMessage());
      }
      infoServiceConnection = null;
      infoService = null;
      infoConnectionPackage = null;
    }
  }

  private void getGpTomInfo(MethodChannel.Result rawResult) {
    final SingleResult result = new SingleResult(rawResult);
    if (infoService == null) {
      result.error("NOT_BOUND", "GPTom info service not bound yet.");
      return;
    }
    try {
      result.success(infoService.getGPTomInfo());
    } catch (Exception e) {
      result.error("INFO_ERROR", e.getMessage());
    }
  }
}
