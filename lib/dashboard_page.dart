import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';

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
      // ── ADD THIS CHANNEL ──
      ..addJavaScriptChannel(
        'PdfChannel',
        onMessageReceived: (msg) => _handlePdfDownload(msg.message),
      )
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (mounted) setState(() => _isLoaded = true);
        },
      ))
      ..loadFlutterAsset('assets/index.html');
  }

  Future<void> _handlePdfDownload(String jsonMsg) async {
    try {
      final data = jsonDecode(jsonMsg) as Map<String, dynamic>;
      final String filename = data['filename'] ?? 'report.pdf';

      // Strip the data URI prefix: "data:application/pdf;base64,..."
      String base64str = data['base64'] as String;
      if (base64str.contains(',')) {
        base64str = base64str.split(',').last;
      }

      final bytes = base64Decode(base64str);

      // Save to app documents directory
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$filename');
      await file.writeAsBytes(bytes);

      // Open the PDF with the device's default viewer
      final result = await OpenFile.open(file.path);

      if (result.type != ResultType.done && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved to: ${file.path}'),
            backgroundColor: const Color(0xFF00A855),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('PDF error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
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