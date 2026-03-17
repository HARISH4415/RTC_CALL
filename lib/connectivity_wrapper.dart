import 'dart:async';
import 'package:flutter/material.dart';
import 'package:internet_connection_checker/internet_connection_checker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ConnectivityWrapper extends StatefulWidget {
  final Widget child;

  const ConnectivityWrapper({super.key, required this.child});

  @override
  State<ConnectivityWrapper> createState() => _ConnectivityWrapperState();
}

class _ConnectivityWrapperState extends State<ConnectivityWrapper> {
  bool isOnline = true;
  bool _isChecking = false;
  late StreamSubscription<InternetConnectionStatus> subscription;
  final checker = InternetConnectionChecker.createInstance();
  final _supabase = Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _checkInitialConnection();
    subscription = checker.onStatusChange.listen((
      InternetConnectionStatus status,
    ) {
      final connected = status == InternetConnectionStatus.connected;
      if (mounted) {
        setState(() {
          isOnline = connected;
        });
        _updateOnlineStatus(connected);
      }
    });
  }

  Future<void> _updateOnlineStatus(bool connected) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user != null) {
        final response = await _supabase.from('profiles').update({
          'is_online': connected,
          'last_seen': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', user.id).select();
        
        if (response.isEmpty) {
          debugPrint('Connectivity update failed: No record updated. Check RLS or if profile exists.');
        } else {
          debugPrint('Connectivity status updated: $connected');
        }
      }
    } catch (e) {
      debugPrint('Error updating connectivity status: $e');
    }
  }

  Future<void> _checkInitialConnection() async {
    setState(() => _isChecking = true);
    
    // Small delay to make it feel responsive if it's too fast
    await Future.delayed(const Duration(milliseconds: 500));
    
    final status = await checker.hasConnection;
    if (mounted) {
      setState(() {
        isOnline = status;
        _isChecking = false;
      });
      // Also update database on initial check
      _updateOnlineStatus(status);
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
        backgroundColor: Colors.white,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.wifi_off_rounded, size: 100, color: Colors.redAccent),
                const SizedBox(height: 24),
                const Text(
                  'Offline',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Please check your internet connection to continue using the app.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, color: Colors.grey),
                ),
                const SizedBox(height: 32),
                ElevatedButton.icon(
                  onPressed: _isChecking ? null : _checkInitialConnection,
                  icon: _isChecking 
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.refresh),
                  label: Text(_isChecking ? 'Checking...' : 'Try Again'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return widget.child;
  }
}
