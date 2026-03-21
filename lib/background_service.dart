import 'package:workmanager/workmanager.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      // Initialize Supabase in the background process
      await Supabase.initialize(
        url: 'https://gdktwrzotmyatdgirjvm.supabase.co',
        anonKey: 'sb_publishable_2_yoOv9cvKOf005tTIVOFQ_uM6Ai4tr',
      );

      final supabase = Supabase.instance.client;
      final user = supabase.auth.currentUser;

      if (user != null) {
        // Update status to Online + Refresh Timestamp
        await supabase.from('profiles').update({
          'is_online': true,
          'last_seen': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', user.id);
      }
      return true;
    } catch (e) {
      return false;
    }
  });
}
