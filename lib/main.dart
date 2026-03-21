import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workmanager/workmanager.dart';
import 'background_service.dart';
import 'connectivity_wrapper.dart';
import 'auth_page.dart';
import 'home_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // TODO: Replace with your actual Supabase URL and Anon Key
  await Supabase.initialize(
    url: 'https://gdktwrzotmyatdgirjvm.supabase.co',
    anonKey: 'sb_publishable_2_yoOv9cvKOf005tTIVOFQ_uM6Ai4tr',
  );

  // Initialize Workmanager for background tasks`
  Workmanager().initialize(
    callbackDispatcher,
    isInDebugMode: false,                                                                                             
  );

  // Register the background fetch task
  Workmanager().registerPeriodicTask(
    "call-signaling-task",
    "fetchCallSignal",
    frequency: const Duration(minutes: 15), // Minimum allowed in Android
    constraints: Constraints(
      networkType: NetworkType.connected,
    ),
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'WebRTC Audio Calls',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      // App wrapper that handles authentication first
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  @override
  void initState() {
    super.initState();
    Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) {
      return const AuthPage();
    } else {
      return const ConnectivityWrapper(child: HomePage());
    }
  }
}