import 'dart:async';
import 'package:flutter/material.dart';
import 'package:internet_connection_checker/internet_connection_checker.dart';

class ConnectivityWrapper extends StatefulWidget {
  final Widget child;

  const ConnectivityWrapper({super.key, required this.child});

  @override
  State<ConnectivityWrapper> createState() => _ConnectivityWrapperState();
}

class _ConnectivityWrapperState extends State<ConnectivityWrapper> {
  bool isOnline = true;
  late StreamSubscription<InternetConnectionStatus> subscription;
  final checker = InternetConnectionChecker.createInstance();

  @override
  void initState() {
    super.initState();
    _checkInitialConnection();
    subscription = checker.onStatusChange.listen((
      InternetConnectionStatus status,
    ) {
      if (mounted) {
        setState(() {
          isOnline = status == InternetConnectionStatus.connected;
        });
      }
    });
  }

  Future<void> _checkInitialConnection() async {
    final status = await checker.hasConnection;
    if (mounted) {
      setState(() {
        isOnline = status;
      });
    }
  }

  @override
  void dispose() {
    subscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!isOnline) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.wifi_off, size: 80, color: Colors.grey),
              SizedBox(height: 20),
              Text(
                'No Internet Connection',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 10),
              Text('This app requires an active internet connection to work.'),
            ],
          ),
        ),
      );
    }
    return widget.child;
  }
}
