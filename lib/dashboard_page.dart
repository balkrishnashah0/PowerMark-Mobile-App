import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late final WebViewController _controller;

  static const _darkBg  = Color(0xFF080C10);
  static const _lightBg = Color(0xFFF0F4F8);

  bool _isLight = false;
  bool _isLoaded = false;

  @override
  void initState() {
    super.initState();

    // Set status bar without calling setState (widget not mounted yet)
    _setStatusBar(false);

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(_darkBg)
      ..addJavaScriptChannel(
        'ThemeChannel',
        onMessageReceived: (msg) {
          final isLight = msg.message == 'light';
          if (mounted) {
            setState(() => _isLight = isLight);
            _setStatusBar(isLight);
          }
        },
      )
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (mounted) setState(() => _isLoaded = true);
        },
      ))
      ..loadFlutterAsset('assets/index.html');
  }

  void _setStatusBar(bool light) {
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: light ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: light ? _lightBg : _darkBg,
      systemNavigationBarIconBrightness: light ? Brightness.dark : Brightness.light,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final bg = _isLight ? _lightBg : _darkBg;

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Stack(
          children: [
            WebViewWidget(controller: _controller),
            if (!_isLoaded)
              Container(
                color: bg,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(
                        color: _isLight
                            ? const Color(0xFF0077AA)
                            : const Color(0xFF00E5FF),
                        strokeWidth: 2,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'POWER MONITOR',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          letterSpacing: 3,
                          color: _isLight
                              ? const Color(0xFF7A96A8)
                              : const Color(0xFF4A6070),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}