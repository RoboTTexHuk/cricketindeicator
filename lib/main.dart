import 'dart:convert';
import 'dart:io';

import 'package:app_tracking_transparency/app_tracking_transparency.dart'
    show AppTrackingTransparency, TrackingStatus;
import 'package:appsflyer_sdk/appsflyer_sdk.dart'
    show AppsFlyerOptions, AppsflyerSdk;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:timezone/data/latest.dart' as tzData;
import 'package:timezone/timezone.dart' as tz;

import 'MainPUSH.dart' show PushWebScreenTWO;


void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);

  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }

  tzData.initializeTimeZones();

  runApp(const MaterialApp(home: PushInitPage()));
}

// FCM Background Handler
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  print("BG Message: ${message.messageId}");
  print("BG Data: ${message.data}");
}

class PushInitPage extends StatefulWidget {
  const PushInitPage({super.key});
  @override
  State<PushInitPage> createState() => _PushInitPageState();
}

class _PushInitPageState extends State<PushInitPage> {
  String? pushToken;

  @override
  void initState() {
    super.initState();

    PushTokenChannel.listen((token) {
      setState(() => pushToken = token);
      print('Push Token received: $token');
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => MainWebScreen(pushToken: token)),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}

class PushTokenChannel {
  static const MethodChannel _channel = MethodChannel('com.example.fcm/token');
  static void listen(Function(String token) onToken) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'setToken') {
        final String token = call.arguments as String;
        onToken(token);
      }
    });
  }
}

class DeviceAppInfoService {
  String? deviceId;
  String? instanceId = "d67f89a0-1234-5678-9abc-def012345678";
  String? platformType;
  String? osVersion;
  String? appVersion;
  String? deviceLanguage;
  String? deviceTimezone;
  bool pushEnabled = true;

  Future<void> init() async {
    final deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final info = await deviceInfo.androidInfo;
      deviceId = info.id;
      platformType = "android";
      osVersion = info.version.release;
    } else if (Platform.isIOS) {
      final info = await deviceInfo.iosInfo;
      deviceId = info.identifierForVendor;
      platformType = "ios";
      osVersion = info.systemVersion;
    }
    final packageInfo = await PackageInfo.fromPlatform();
    appVersion = packageInfo.version;
    deviceLanguage = Platform.localeName.split('_')[0];
    deviceTimezone = tz.local.name;
  }

  Map<String, dynamic> toMap({String? fcmToken}) {
    return {
      "fcm_token": fcmToken ?? 'default_fcm_token',
      "device_id": deviceId ?? 'default_device_id',
      "app_name": "indicricket",
      "instance_id": instanceId ?? 'default_instance_id',
      "platform": platformType ?? 'unknown_platform',
      "os_version": osVersion ?? 'default_os_version',
      "app_version": appVersion ?? 'default_app_version',
      "language": deviceLanguage ?? 'en',
      "timezone": deviceTimezone ?? 'UTC',
      "push_enabled": pushEnabled,
    };
  }
}

class AppsFlyerService {
  AppsflyerSdk? appsFlyerSdk;
  String appsFlyerId = "";
  String conversionData = "";

  void init(VoidCallback onUpdate) {
    final options = AppsFlyerOptions(
      afDevKey: "qsBLmy7dAXDQhowM8V3ca4",
      appId: "6745818621",
      showDebug: true,
    );
    appsFlyerSdk = AppsflyerSdk(options);
    appsFlyerSdk?.initSdk(
      registerConversionDataCallback: true,
      registerOnAppOpenAttributionCallback: true,
      registerOnDeepLinkingCallback: true,
    );
    appsFlyerSdk?.startSDK(
      onSuccess: () => print("AppsFlyer started"),
      onError: (int code, String msg) => print("AppsFlyer error $code $msg"),
    );
    appsFlyerSdk?.onInstallConversionData((res) {
      conversionData = res.toString();
      appsFlyerId = res['payload']['af_status'].toString();
      onUpdate();
    });
    appsFlyerSdk?.getAppsFlyerUID().then((value) {
      appsFlyerId = value.toString();
      onUpdate();
    });
  }
}

class MainWebScreen extends StatefulWidget {
  final String? pushToken;
  const MainWebScreen({super.key, required this.pushToken});
  @override
  State<MainWebScreen> createState() => _MainWebScreenState();
}

class _MainWebScreenState extends State<MainWebScreen> {
  late InAppWebViewController webViewController;
  bool isPageLoading = false;
  final String mainUrl = "https://getapi.mycricket.best";

  // Services
  final deviceAppInfo = DeviceAppInfoService();
  final appsFlyerService = AppsFlyerService();

  @override
  void initState() {
    super.initState();

    _initFirebaseListeners();
    _initAppTrackingTransparency();
    appsFlyerService.init(() => setState(() {}));
    _setupPushNotificationChannel();
    _initDeviceAndFirebase();

    // Повторная инициализация ATT через 2 сек
    Future.delayed(const Duration(seconds: 2), _initAppTrackingTransparency);
    // Передача device/app данных в web через 6 сек
    Future.delayed(const Duration(seconds: 6), () {
      _sendDeviceDataToWeb();
      _sendRawAppsFlyerDataToWeb();
    });
  }

  void _initFirebaseListeners() {
    FirebaseMessaging.onMessage.listen((RemoteMessage msg) {
      final uri = msg.data['uri'];
      if (uri != null) {
        _loadUrl(uri.toString());
      } else {
        _reloadMainUrl();
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage msg) {
      final uri = msg.data['uri'];
      if (uri != null) {
        _loadUrl(uri.toString());
      } else {
        _reloadMainUrl();
      }
    });
  }

  void _setupPushNotificationChannel() {
    MethodChannel('com.example.fcm/notification')
        .setMethodCallHandler((call) async {
      if (call.method == "onNotificationTap") {
        final Map<String, dynamic> data =
        Map<String, dynamic>.from(call.arguments);
        final url = data["uri"];
        if (url != null && !url.contains("Нет URI")) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (context) => PushWebScreenTWO(loadURL: url)),
                (route) => false,
          );
        }
      }
    });
  }

  Future<void> _initDeviceAndFirebase() async {
    try {
      await deviceAppInfo.init();
      await _initFirebaseMessaging();
      if (webViewController != null) {
        _sendDeviceDataToWeb();
      }
    } catch (e) {
      debugPrint("Device data init error: $e");
    }
  }

  Future<void> _initFirebaseMessaging() async {
    FirebaseMessaging messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);
  }

  Future<void> _initAppTrackingTransparency() async {
    final status = await AppTrackingTransparency.trackingAuthorizationStatus;
    if (status == TrackingStatus.notDetermined) {
      await Future.delayed(const Duration(milliseconds: 1000));
      await AppTrackingTransparency.requestTrackingAuthorization();
    }
    final uuid = await AppTrackingTransparency.getAdvertisingIdentifier();
    print("ATT AdvertisingIdentifier: $uuid");
  }

  void _loadUrl(String uri) async {
    if (webViewController != null) {
      await webViewController.loadUrl(
        urlRequest: URLRequest(url: WebUri(uri)),
      );
    }
  }

  void _reloadMainUrl() async {
    Future.delayed(const Duration(seconds: 3), () {
      if (webViewController != null) {
        webViewController.loadUrl(
          urlRequest: URLRequest(url: WebUri(mainUrl)),
        );
      }
    });
  }

  Future<void> _sendDeviceDataToWeb() async {
    setState(() => isPageLoading = true);
    try {
      final map = deviceAppInfo.toMap(fcmToken: widget.pushToken);
      await webViewController.evaluateJavascript(source: '''
      localStorage.setItem('app_data', JSON.stringify(${jsonEncode(map)}));
      ''');
    } finally {
      setState(() => isPageLoading = false);
    }
  }

  Future<void> _sendRawAppsFlyerDataToWeb() async {
    final data = {
      "content": {
        "af_data": appsFlyerService.conversionData,
        "af_id": appsFlyerService.appsFlyerId,
        "fb_app_name": "indicricket",
        "app_name": "indicricket",
        "deep": null,
        "bundle_identifier": "com.koilktoil.crickeindicator",
        "app_version": "1.0.0",
        "apple_id": "6745818621",
        "fcm_token": widget.pushToken ?? "default_fcm_token",
        "device_id": deviceAppInfo.deviceId ?? "default_device_id",
        "instance_id": deviceAppInfo.instanceId ?? "default_instance_id",
        "platform": deviceAppInfo.platformType ?? "unknown_platform",
        "os_version": deviceAppInfo.osVersion ?? "default_os_version",
        "app_version": deviceAppInfo.appVersion ?? "default_app_version",
        "language": deviceAppInfo.deviceLanguage ?? "en",
        "timezone": deviceAppInfo.deviceTimezone ?? "UTC",
        "push_enabled": deviceAppInfo.pushEnabled,
        "useruid": appsFlyerService.appsFlyerId,
      },
    };
    final jsonString = jsonEncode(data);
    print("SendRawData: $jsonString");

    await webViewController.evaluateJavascript(
      source: "sendRawData(${jsonEncode(jsonString)});",
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea( // <--- добавлено!
        child: Container(
          color: Colors.black, // ЧЁРНЫЙ ФОН
          child: Stack(
            children: [
              InAppWebView(
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  disableDefaultErrorPage: true,
                  mediaPlaybackRequiresUserGesture: false,
                  allowsInlineMediaPlayback: true,
                  allowsPictureInPictureMediaPlayback: true,
                  useOnDownloadStart: true,
                  javaScriptCanOpenWindowsAutomatically: true,
                ),
                initialUrlRequest: URLRequest(url: WebUri(mainUrl)),
                onWebViewCreated: (controller) {
                  webViewController = controller;
                  webViewController.addJavaScriptHandler(
                    handlerName: 'onServerResponse',
                    callback: (args) {
                      print("JS args: $args");
                      return args.reduce((curr, next) => curr + next);
                    },
                  );
                },
                onLoadStart: (controller, url) {
                  setState(() => isPageLoading = true);
                },
                onLoadStop: (controller, url) async {
                  await controller.evaluateJavascript(
                    source: "console.log('Hello from JS!');",
                  );
                  await _sendDeviceDataToWeb();
                },
                shouldOverrideUrlLoading: (controller, navigationAction) async {
                  return NavigationActionPolicy.ALLOW;
                },
              ),
              if (isPageLoading)
                const Center(
                  child: SizedBox(
                    height: 80,
                    width: 80,
                    child: CircularProgressIndicator(
                      strokeWidth: 5,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.deepPurple),
                      backgroundColor: Colors.grey,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

