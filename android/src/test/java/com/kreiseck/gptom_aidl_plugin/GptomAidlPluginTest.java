package com.kreiseck.gptom_aidl_plugin;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.robolectric.Shadows.shadowOf;

import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
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
import java.util.HashMap;
import java.util.Map;

import cn.nexgo.smartconnect.ISmartconnectService;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34)
public class GptomAidlPluginTest {

  private GptomAidlPlugin plugin;
  private MethodChannel.Result result;

  @Before
  public void setUp() {
    plugin = new GptomAidlPlugin();

    FlutterPlugin.FlutterPluginBinding binding = mock(FlutterPlugin.FlutterPluginBinding.class);
    when(binding.getApplicationContext()).thenReturn(RuntimeEnvironment.getApplication());
    when(binding.getBinaryMessenger()).thenReturn(mock(BinaryMessenger.class));
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
    ISmartconnectService service = mock(ISmartconnectService.class);
    Field field = GptomAidlPlugin.class.getDeclaredField("gptomService");
    field.setAccessible(true);
    field.set(plugin, service);

    Map<String, Object> args = new HashMap<>();
    args.put("requestJson",
        "{\"transactionID\":\"tx\",\"transactionType\":1,\"amount\":1111,"
            + "\"openGptomUI\":false,\"redirect\":true}");
    plugin.onMethodCall(new MethodCall("requestTransactionV2", args), result);

    ArgumentCaptor<String> jsonCaptor = ArgumentCaptor.forClass(String.class);
    verify(service).transactionRequestV2(jsonCaptor.capture(), any());

    JsonObject sent = JsonParser.parseString(jsonCaptor.getValue()).getAsJsonObject();
    // Steuerfelder gehören nicht ins GPTom-Request-JSON
    assertFalse(sent.has("openGptomUI"));
    assertFalse(sent.has("redirect"));
    // Cent-Betrag bleibt Ganzzahl (nicht "1111.0")
    assertEquals("1111", sent.get("amount").getAsString());
    assertEquals("tx", sent.get("transactionID").getAsString());
  }
}
