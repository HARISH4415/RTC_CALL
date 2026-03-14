import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:uuid/uuid.dart';
import 'package:permission_handler/permission_handler.dart';
import 'call_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _supabase = Supabase.instance.client;
  List<Map<String, dynamic>> _profiles = [];
  bool _isLoading = true;
  RealtimeChannel? _signalingChannel;
  RealtimeChannel? _presenceChannel;
  List<Presence> _onlineUsers = [];

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _fetchProfiles();
    _initSignaling();
    _initPresence();
    _listenToCallKitEvents();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.microphone,
      Permission.notification,
    ].request();
    
    // For Android 14+ full screen intent doesn't need runtime request but 
    // it's good to ensure the user knows.
  }

  Future<void> _fetchProfiles() async {
    try {
      final myId = _supabase.auth.currentUser!.id;

      // 2. Fetch all profiles except mine
      final res = await _supabase.from('profiles').select();
      final allProfiles = List<Map<String, dynamic>>.from(
        res,
      ).where((p) => p['id'] != myId).toList();

      setState(() {
        // Relaxing role filter for testing - allows users to see everyone
        _profiles = allProfiles; 
      });
    } catch (e) {
      debugPrint('Error fetching profiles: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _initPresence() {
    final myId = _supabase.auth.currentUser!.id;
    _presenceChannel = _supabase.channel('online-presence');

    _presenceChannel!
        .onPresenceSync((payload) {
          _updatePresenceState();
        })
        .onPresenceJoin((payload) {
          _updatePresenceState();
        })
        .onPresenceLeave((payload) {
          _updatePresenceState();
        })
        .subscribe((status, error) async {
          if (status == RealtimeSubscribeStatus.subscribed) {
            await _presenceChannel!.track({
              'user_id': myId,
              'online_at': DateTime.now().toIso8601String(),
            });
          }
        });
  }

  void _updatePresenceState() {
    if (!mounted) return;
    try {
      final state = _presenceChannel!.presenceState();
      List<Presence> allPresences = [];

      for (final item in state) {
        allPresences.addAll(item.presences);
      }

      setState(() {
        _onlineUsers = allPresences;
      });
    } catch (e) {
      debugPrint('Error updating presence state: $e');
    }
  }

  bool _isUserOnline(String userId) {
    if (_onlineUsers.isEmpty) return false;
    return _onlineUsers.any((presence) => presence.payload['user_id'] == userId);
  }

  void _initSignaling() {
    final myId = _supabase.auth.currentUser!.id;
    // TARGETED CHANNEL: Each user listens for their OWN Id
    _signalingChannel = _supabase.channel('signaling:$myId');

    _signalingChannel!
        .onBroadcast(
          event: 'call_offer',
          callback: (payload) {
            debugPrint('Received private call_offer signal');
            final data = payload['payload'] ?? payload;
            _showCallKitIncoming(data);
          },
        )
        .subscribe((status, error) {
          debugPrint('My signaling inbox ($myId) status: $status');
        });
  }

  Future<void> _showCallKitIncoming(Map<String, dynamic> offerPayload) async {
    if (!mounted) return;
    final callId = const Uuid().v4();
    final callerName = offerPayload['caller_name'] ?? 'Someone';
    
    final params = CallKitParams(
      id: callId,
      nameCaller: callerName,
      appName: 'RTC Call',
      handle: offerPayload['caller_phone'] ?? 'Audio Call',
      type: 0, // Audio
      duration: 30000,
      android: const AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#075E54',
        actionColor: '#4CAF50',
      ),
      ios: const IOSParams(
        iconName: 'AppIcon',
        handleType: 'generic',
        supportsVideo: false,
        maximumCallGroups: 1,
        maximumCallsPerCallGroup: 1,
        audioSessionMode: 'default',
        audioSessionActive: true,
      ),
      extra: offerPayload,
    );

    await FlutterCallkitIncoming.showCallkitIncoming(params);
  }

  void _listenToCallKitEvents() {
    FlutterCallkitIncoming.onEvent.listen((event) {
      if (!mounted) return;
      switch (event!.event) {
        case Event.actionCallAccept:
          final offerPayload = Map<String, dynamic>.from(event.body['extra']);
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => CallPage(
                peerId: offerPayload['caller'],
                isCaller: false,
                initialOffer: offerPayload,
              ),
            ),
          );
          break;
        default:
          break;
      }
    });
  }

  @override
  void dispose() {
    _signalingChannel?.unsubscribe();
    _presenceChannel?.unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts'),
        actions: [
          IconButton(
            onPressed: () => _supabase.auth.signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _profiles.isEmpty
              ? const Center(child: Text('No contacts found'))
              : ListView.builder(
                  itemCount: _profiles.length,
                  itemBuilder: (context, index) {
                    final profile = _profiles[index];
                    final isOnline = _isUserOnline(profile['id']);
                    return ListTile(
                      leading: Stack(
                        children: [
                          CircleAvatar(
                            child:
                                Text(profile['name']?.substring(0, 1) ?? 'U'),
                          ),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: isOnline ? Colors.green : Colors.grey,
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: Colors.white, width: 2),
                              ),
                            ),
                          ),
                        ],
                      ),
                      title: Text(
                        profile['name'] ?? profile['phone'] ?? 'Unknown User',
                      ),
                      subtitle: Text(
                          '${profile['role'] ?? 'user'} • ${isOnline ? "Online" : "Offline"}'),
                      trailing: IconButton(
                        icon: Icon(Icons.call,
                            color: isOnline ? Colors.teal : Colors.grey),
                        onPressed: isOnline
                            ? () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => CallPage(
                                        peerId: profile['id'], isCaller: true),
                                  ),
                                );
                              }
                            : () {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('User is offline.')),
                                );
                              },
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showDialDialog,
        backgroundColor: Colors.teal,
        child: const Icon(Icons.dialpad),
      ),
    );
  }

  void _showDialDialog() {
    final phoneController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Call by Number'),
        content: TextField(
          controller: phoneController,
          decoration: const InputDecoration(
            labelText: 'Phone Number',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.phone),
          ),
          keyboardType: TextInputType.phone,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _callByPhoneNumber(phoneController.text.trim());
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
            child: const Text('Call', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _callByPhoneNumber(String phoneNumber) async {
    if (phoneNumber.isEmpty) return;

    try {
      final res = await _supabase
          .from('profiles')
          .select()
          .eq('phone', phoneNumber)
          .maybeSingle();

      if (res != null) {
        if (!_isUserOnline(res['id'])) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('User is offline.')),
          );
          return;
        }

        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CallPage(peerId: res['id'], isCaller: true),
          ),
        );
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This number is not registered.')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error finding user: $e')));
    }
  }
}


