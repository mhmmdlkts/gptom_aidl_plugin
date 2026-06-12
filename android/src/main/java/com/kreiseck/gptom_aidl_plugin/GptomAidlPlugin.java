package com.kreiseck.gptom_aidl_plugin;

import androidx.annotation.NonNull;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.RemoteException;
import android.util.Log;

import java.util.Map;
import java.util.HashMap;
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
 * V2-JSON-Schnittstellen an Flutter durch. Über "isDev" kann zwischen
 * Dev- und Prod-Package gewählt werden.
 */
public class GptomAidlPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {

  private static final String TAG = "GptomAidlPlugin";
  private static final String DEV_PACKAGE = "com.globalpayments.atom.dev";
  private static final String PROD_PACKAGE = "com.globalpayments.atom";
  private static final String PAYMENT_SERVICE_CLASS = "com.globalpayments.atom.data.external.api.NexgoAPIService";
  private static final String LOGIN_SERVICE_ACTION = "com.globalpayments.atom.BIND_TO_LOGIN_SERVICE";
  private static final String INFO_SERVICE_ACTION = "com.globalpayments.atom.BIND_TO_INFO_SERVICE";
  private static final long BIND_TIMEOUT_MS = 5000;

  private MethodChannel channel;
  private Context applicationContext;
  private final Handler mainHandler = new Handler(Looper.getMainLooper());

  private ISmartconnectService gptomService;
  private ServiceConnection serviceConnection;

  private IGPTomLoginService loginService;
  private ServiceConnection loginServiceConnection;

  private IGPTomInfoService infoService;
  private ServiceConnection infoServiceConnection;

  private boolean isDev;

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

    void success(Object value) {
      if (answered.compareAndSet(false, true)) {
        mainHandler.post(() -> result.success(value));
      }
    }

    void error(String code, String message) {
      if (answered.compareAndSet(false, true)) {
        mainHandler.post(() -> result.error(code, message, null));
      }
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
      case "bindService": {
        isDev = boolArgument(call, "isDev");
        bindPaymentService(result);
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
        isDev = boolArgument(call, "isDev");
        bindLoginService(result);
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
        isDev = boolArgument(call, "isDev");
        bindInfoService(result);
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

  private String targetPackage() {
    return isDev ? DEV_PACKAGE : PROD_PACKAGE;
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
  private void bindPaymentService(MethodChannel.Result rawResult) {
    final SingleResult result = new SingleResult(rawResult);
    if (gptomService != null) {
      result.success(true);
      return;
    }

    try {
      Intent intent = new Intent();
      intent.setComponent(new ComponentName(targetPackage(), PAYMENT_SERVICE_CLASS));

      if (serviceConnection != null) {
        try {
          applicationContext.unbindService(serviceConnection);
        } catch (Exception ignored) {
        }
        serviceConnection = null;
      }

      serviceConnection = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, IBinder service) {
          gptomService = ISmartconnectService.Stub.asInterface(service);
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

      // bindService() liefert nur "Anfrage angenommen" – verbunden sind wir erst
      // bei onServiceConnected. Falls die Verbindung nie zustande kommt, nicht
      // ewig hängen lassen.
      mainHandler.postDelayed(() -> {
        if (gptomService == null) {
          result.success(false);
        }
      }, BIND_TIMEOUT_MS);
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

      // Steuerfelder gehören nicht ins GPTom-Request-JSON
      parsed.remove("redirect");
      parsed.remove("openGptomUI");

      String finalJson = parsed.toString();

      gptomService.transactionRequestV2(finalJson, new ITransactionResultListener.Stub() {
        @Override
        public void onTransactionV2Result(String resultJson) {
          result.success(resultJson);
        }

        @Override
        public void onTransactionResult(
          cn.nexgo.smartconnect.model.TransactionResultEntity transactionResultEntity
        ) {
          // V1, deprecated
        }
      });

      if (openGptomUI) {
        Intent openGptom = applicationContext.getPackageManager()
                .getLaunchIntentForPackage(targetPackage());
        if (openGptom != null) {
          openGptom.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
          applicationContext.startActivity(openGptom);
        } else {
          Log.e(TAG, "requestTransactionV2: GPTom app not found!");
        }
      }
    } catch (RemoteException e) {
      result.error("REMOTE_EXCEPTION", e.getMessage());
    } catch (Exception e) {
      result.error("INVALID_REQUEST", e.getMessage());
    }
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
  private void bindLoginService(MethodChannel.Result rawResult) {
    final SingleResult result = new SingleResult(rawResult);
    if (loginService != null) {
      result.success(true);
      return;
    }

    try {
      Intent intent = new Intent(LOGIN_SERVICE_ACTION);
      intent.setPackage(targetPackage());

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

      loginServiceConnection = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, IBinder binder) {
          loginService = IGPTomLoginService.Stub.asInterface(binder);
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

      mainHandler.postDelayed(() -> {
        if (loginService == null) {
          result.success(false);
        }
      }, BIND_TIMEOUT_MS);
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
  private void bindInfoService(MethodChannel.Result rawResult) {
    final SingleResult result = new SingleResult(rawResult);
    if (infoService != null) {
      result.success(true);
      return;
    }

    try {
      Intent intent = new Intent(INFO_SERVICE_ACTION);
      intent.setPackage(targetPackage());

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

      infoServiceConnection = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, IBinder binder) {
          infoService = IGPTomInfoService.Stub.asInterface(binder);
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

      mainHandler.postDelayed(() -> {
        if (infoService == null) {
          result.success(false);
        }
      }, BIND_TIMEOUT_MS);
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
