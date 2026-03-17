import 'package:workmanager/workmanager.dart';
import 'package:supabase_flutter/supabase_flutter.dart';


@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    // This is the background task that checks for new signals
    try {
      if (Supabase.instance.client.auth.currentUser == null) {
        // Re-initialize if necessary, though it should stay initialized
        await Supabase.initialize(
          url: 'https://pxnbdocnrrqjbxmdfges.supabase.co',
          anonKey: 'sb_publishable_-qV0r5JOP1hohUtkZoLubA_O7hMqG79',
        );
      }

      final myId = Supabase.instance.client.auth.currentUser?.id;
      if (myId == null) return true;

      // Update online status in database
      await Supabase.instance.client.from('profiles').update({
        'last_seen': DateTime.now().toUtc().toIso8601String(),
        'is_online': true,
      }).eq('id', myId);
      
      return true;
    } catch (e) {
      return false;
    }
  });
}
