package com.kreiseck.gptom_aidl_plugin;

import androidx.annotation.NonNull;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.RemoteException;
import android.util.Log;

import java.util.Map;
import java.util.HashMap;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

import com.google.gson.Gson;
import com.google.gson.reflect.TypeToken;

import cn.nexgo.smartconnect.ISmartconnectService;
import cn.nexgo.smartconnect.listener.IInquireResultListener;
import cn.nexgo.smartconnect.listener.IStateResultListener;
import cn.nexgo.smartconnect.listener.ITransactionRegisterListener;
import cn.nexgo.smartconnect.listener.ITransactionResultListener;

/**
 * GptomAidlPlugin
 *
 * Ein Beispiel-Plugin, das zwischen Dev- und Prod-Package wählen kann,
 * basierend auf einem booleschen Parameter "isDev".
 */
public class GptomAidlPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {

  private static final String TAG = "GptomAidlPlugin";
  private static final String DEV_PACKAGE = "com.globalpayments.atom.dev";
  private static final String PROD_PACKAGE = "com.globalpayments.atom";

  private MethodChannel channel;
  private Context applicationContext;

  private ISmartconnectService gptomService;
  private ServiceConnection serviceConnection;
  private boolean isDev;

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
    unbindGptomService();
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    Log.d(TAG, "onMethodCall: " + call.method);
    switch (call.method) {
      case "existGpTomApp": {
        boolean checkDev;
        try {
          checkDev = call.argument("isDev");
        } catch (Exception e) {
          checkDev = false;
        }

        existGpTomApp(checkDev, result);
        break;
      }
      case "bindService": {
        //print

        Log.d(TAG,  "onMethodCall: bindService called");

        try {
          isDev = call.argument("isDev");
        } catch (Exception e) {
          isDev = false;
        }

        bindServiceMethod(result);
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
      default:
        result.notImplemented();
        break;
    }
  }

  private void existGpTomApp(boolean checkDev, MethodChannel.Result result) {
    // Wähle je nach isDev das richtige Package
    String packageName = checkDev ? DEV_PACKAGE : PROD_PACKAGE;

    try {
      // Versuche, PackageInfo zu bekommen
      applicationContext.getPackageManager().getApplicationInfo(packageName, 0);
      // Wenn das klappt, ist die App installiert
      result.success(true);
    } catch (Exception e) {
      // NameNotFoundException -> nicht installiert
      result.success(false);
    }
  }

  // ---------------------------------------------------------------------------
  // BIND SERVICE
  // ---------------------------------------------------------------------------
  private void bindServiceMethod(MethodChannel.Result result) {
    Log.d(TAG, "bindServiceMethod: isDev = " + isDev);
    if (gptomService != null) {
      result.success(true);
      return;
    }

    try {
      Intent intent = new Intent();

      // Je nach isDev das Paket auswählen
      String packageName = isDev ? DEV_PACKAGE : PROD_PACKAGE;

      // Service-Klasse, je nach Version kann das abweichen
      String serviceClassName = "com.globalpayments.atom.data.external.api.NexgoAPIService";

      ComponentName component = new ComponentName(isDev ? DEV_PACKAGE : PROD_PACKAGE, serviceClassName);
      intent.setComponent(component);

      int flags = Context.BIND_AUTO_CREATE;
      // Android 14+ only: set BIND_ALLOW_ACTIVITY_STARTS if available (avoid hard-coded values)
      try {
        java.lang.reflect.Field f = Context.class.getField("BIND_ALLOW_ACTIVITY_STARTS");
        flags |= f.getInt(null);
      } catch (Throwable ignored) {
        // older Android versions: flag not available
      }

      if (serviceConnection == null) {
        serviceConnection = new ServiceConnection() {
          @Override
          public void onServiceConnected(ComponentName name, IBinder service) {
            gptomService = ISmartconnectService.Stub.asInterface(service);
          }

          @Override
          public void onServiceDisconnected(ComponentName name) {
            gptomService = null;
          }
        };
      }

      boolean bound = applicationContext.bindService(intent, serviceConnection, flags);

      if (bound) {
        result.success(true);
      } else {
        result.success(false);
      }
    } catch (Exception e) {
      result.error("BIND_ERROR", e.getMessage(), null);
    }
  }

  private void unbindGptomService() {
    if (serviceConnection != null && gptomService != null) {
      try {
        applicationContext.unbindService(serviceConnection);
        gptomService = null;
        serviceConnection = null;
        Log.d(TAG, "unbindGptomService: unbound service");
      } catch (Exception e) {
        Log.e(TAG, "unbindGptomService: error unbinding service " + e.getMessage());
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 1) registerTransactionV2
  // ---------------------------------------------------------------------------
  private void registerTransactionV2(String registerJson, MethodChannel.Result flutterResult) {
    if (gptomService == null) {
      flutterResult.error("NOT_BOUND", "GPTom Service not bound yet.", null);
      return;
    }
    try {
      gptomService.transactionRegisterV2(registerJson, new ITransactionRegisterListener.Stub() {
        @Override
        public void onRegisterV2Result(String resultJson) throws RemoteException {
          Log.d(TAG, "registerTransactionV2 -> onRegisterV2Result: " + resultJson);
          sendSuccessToFlutter(flutterResult, resultJson);
        }

        @Override
        public void onRegisterResult(cn.nexgo.smartconnect.model.RegisterResultEntity registerResultEntity) {
          // V1, deprecated
        }
      });
    } catch (RemoteException e) {
      sendErrorToFlutter(flutterResult, "REMOTE_EXCEPTION", e.getMessage());
    }
  }

  // ---------------------------------------------------------------------------
  // 2) requestTransactionV2
  // ---------------------------------------------------------------------------
  private void requestTransactionV2(String requestJson, MethodChannel.Result flutterResult) {
    if (gptomService == null) {
      flutterResult.error("NOT_BOUND", "GPTom Service not bound yet.", null);
      return;
    }
    try {
      // 1) Parse das eingehende JSON in eine Map
      Map<String, Object> parsed = new Gson().fromJson(
              requestJson, new TypeToken<Map<String, Object>>(){}.getType()
      );

      if (parsed.containsKey("cancelMode")) {
        Object cancelModeObj = parsed.get("cancelMode");
        if (cancelModeObj instanceof Double) {
          parsed.put("cancelMode", ((Double) cancelModeObj).intValue());
        }
      }

      if (parsed.containsKey("transactionType")) {
        Object cancelModeObj = parsed.get("transactionType");
        if (cancelModeObj instanceof Double) {
          parsed.put("transactionType", ((Double) cancelModeObj).intValue());
        }
      }

      // === 2) openGptomUI-Feld auswerten ===
      Object openUIVal = parsed.get("openGptomUI");
      boolean openGptomUI = false;
      if (openUIVal instanceof Boolean) {
        openGptomUI = (Boolean) openUIVal;
      }

      // 2.1) Vor dem finalen JSON: Wir entfernen "redirect"/"openGptomUI" aus der Map,
      parsed.remove("redirect");
      parsed.remove("openGptomUI");

      // 4) Konvertiere das map wieder in JSON
      String finalJson = new Gson().toJson(parsed);

      // 5) GPTom-SDK aufrufen
      gptomService.transactionRequestV2(finalJson, new ITransactionResultListener.Stub() {
        @Override
        public void onTransactionV2Result(String result) throws RemoteException {
          Log.d(TAG, "requestTransactionV2 -> finalJson: " + finalJson);
          Log.d(TAG, "requestTransactionV2 -> onTransactionV2Result: " + result);
          sendSuccessToFlutter(flutterResult, result);
        }

        @Override
        public void onTransactionResult(
          cn.nexgo.smartconnect.model.TransactionResultEntity transactionResultEntity
        ) {
          // V1, deprecated
        }
      });

      // 5) Wenn openGptomUI == true, GPTom-App starten
      //    (Dev oder Prod – je nachdem, wie du es an bindServiceMethod übergeben hast).
      if (openGptomUI) {
        String targetPackage = isDev ? DEV_PACKAGE : PROD_PACKAGE;

        Intent openGptom = applicationContext.getPackageManager()
                .getLaunchIntentForPackage(targetPackage);
        if (openGptom != null) {
          openGptom.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
          applicationContext.startActivity(openGptom);
        } else {
          Log.e(TAG, "requestTransactionV2: GPTom app not found!");
        }
      }
    } catch (RemoteException e) {
      sendErrorToFlutter(flutterResult, "REMOTE_EXCEPTION", e.getMessage());
    }
  }

  // ---------------------------------------------------------------------------
  // 3) stateRequest
  // ---------------------------------------------------------------------------
  private void stateRequest(String transactionId, MethodChannel.Result flutterResult) {
    if (gptomService == null) {
      flutterResult.error("NOT_BOUND", "GPTom Service not bound yet.", null);
      return;
    }
    try {
      gptomService.stateRequest(transactionId, new IStateResultListener.Stub() {
        @Override
        public void onStateResult(String resultJson) throws RemoteException {
          sendSuccessToFlutter(flutterResult, resultJson);
        }
      });
    } catch (RemoteException e) {
      sendErrorToFlutter(flutterResult, "REMOTE_EXCEPTION", e.getMessage());
    }
  }

  // ---------------------------------------------------------------------------
  // 4) inquireTransaction
  // ---------------------------------------------------------------------------
  private void inquireTransaction(String transactionId, MethodChannel.Result flutterResult) {
    if (gptomService == null) {
      flutterResult.error("NOT_BOUND", "GPTom Service not bound yet.", null);
      return;
    }
    try {
      gptomService.TransactionInquire(transactionId, new IInquireResultListener.Stub() {
        @Override
        public void onInquireResult(cn.nexgo.smartconnect.model.InquireResultEntity inquireResultEntity) {
          String json = new Gson().toJson(inquireResultEntity);
          sendSuccessToFlutter(flutterResult, json);
        }
      });
    } catch (RemoteException e) {
      sendErrorToFlutter(flutterResult, "REMOTE_EXCEPTION", e.getMessage());
    }
  }

  // ---------------------------------------------------------------------------
  // Hilfsfunktionen zum Senden ans Flutter UI
  // ---------------------------------------------------------------------------
  private void sendSuccessToFlutter(MethodChannel.Result flutterResult, String resultData) {
    new Handler(Looper.getMainLooper()).post(() -> flutterResult.success(resultData));
  }

  private void sendErrorToFlutter(MethodChannel.Result flutterResult, String code, String message) {
    new Handler(Looper.getMainLooper()).post(() -> flutterResult.error(code, message, null));
  }
}