import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math';

import 'package:web/web.dart';

@JS('PocketBridge.supported') external JSString bridgeSupported();
@JS('PocketBridge.list') external JSPromise<JSString> bridgeList();
@JS('PocketBridge.save') external JSPromise<JSString> bridgeSave(String meta, Blob blob);
@JS('PocketBridge.getBlob') external JSPromise<Blob> bridgeGetBlob(String id);
@JS('PocketBridge.update') external JSPromise<JSString> bridgeUpdate(String id, String patch);
@JS('PocketBridge.remove') external JSPromise<JSAny?> bridgeRemove(String id);
@JS('PocketBridge.clear') external JSPromise<JSAny?> bridgeClear();
@JS('PocketBridge.estimate') external JSPromise<JSString> bridgeEstimate();
@JS('PocketBridge.persist') external JSPromise<JSBoolean> bridgePersist();
@JS('PocketBridge.listPlaylists') external JSPromise<JSString> bridgeListPlaylists();
@JS('PocketBridge.savePlaylist') external JSPromise<JSString> bridgeSavePlaylist(String value);
@JS('PocketBridge.removePlaylist') external JSPromise<JSAny?> bridgeRemovePlaylist(String id);
@JS('PocketBridge.download') external void bridgeDownload(Blob blob, String name);
@JS('PocketBridge.share') external JSPromise<JSBoolean> bridgeShare(Blob blob, String name, String title);
@JS('PocketBridge.registerSw') external void registerSw();

T el<T extends Element>(String id) => document.getElementById(id) as T;
void on(String id, String type, void Function(Event) handler) =>
    el<Element>(id).addEventListener(type, handler.toJS);

class Recording {
  Recording(this.data);
  final Map<String, dynamic> data;
  String get id => data['id'] as String;
  String get title => data['title'] as String;
  String get createdAt => data['createdAt'] as String;
  double get duration => (data['duration'] as num?)?.toDouble() ?? 0;
  int get size => (data['size'] as num?)?.toInt() ?? 0;
  String get mimeType => data['mimeType'] as String? ?? 'audio/mp4';
  String get extension => data['fileExtension'] as String? ?? 'm4a';
  bool get favorite => data['favorite'] == true;
}

class App {
  final audio = el<HTMLAudioElement>('audio');
  List<Recording> recordings = [];
  List<Map<String, dynamic>> playlists = [];
  String? activePlaylistId;
  Recording? sheetRecording;
  double? miniTouchStartY;
  double? playerTouchStartY, sheetTouchStartY;
  bool playerSwipeCanCollapse = false;
  bool playerHistoryActive = false;
  Recording? current;
  MediaRecorder? recorder;
  MediaStream? stream;
  final chunks = <Blob>[];
  Timer? recordTimer, progressTimer, sleepTimer;
  DateTime? startedAt, sleepAt;
  Duration paused = Duration.zero;
  DateTime? pauseStarted;
  String currentUrl = '';
  bool shuffle = false;
  bool singlePlayback = false;
  String repeat = 'off';
  String query = '';
  String sort = 'old';
  bool cancelling = false;
  List<String> playbackQueueIds = [];
  Map<String, dynamic> capabilities = {};

  Future<void> init() async {
    capabilities = jsonDecode(bridgeSupported().toDart) as Map<String, dynamic>;
    _bind();
    _renderCompatibility();
    await reload();
    await reloadPlaylists();
    await refreshStorage();
    registerSw();
    window.addEventListener('beforeunload', ((BeforeUnloadEvent e) {
      if (recorder != null && recorder!.state != 'inactive') e.preventDefault();
    }).toJS);
    document.addEventListener('visibilitychange', ((Event _) => _syncPlayer()).toJS);
    window.addEventListener('popstate', ((PopStateEvent _) { if(playerHistoryActive){playerHistoryActive=false;showLibrary();} }).toJS);
  }

  void _bind() {
    on('recordFab', 'click', (_) => showView('recordView'));
    on('startInsideBtn', 'click', (_) => startRecording());
    on('pauseRecordBtn', 'click', (_) => toggleRecordPause());
    on('stopRecordBtn', 'click', (_) => stopRecording());
    on('cancelRecordBtn', 'click', (_) => cancelRecording());
    on('recordCloseBtn', 'click', (_) => closeRecord());
    on('settingsBtn', 'click', (_) => showView('settingsView'));
    on('settingsCloseBtn', 'click', (_) => showLibrary());
    on('playerCloseBtn', 'click', (_) => collapsePlayer());
    on('importBtn', 'click', (_) => el<HTMLInputElement>('fileInput').click());
    on('playAllBtn', 'click', (_) => playAll());
    on('createPlaylistBtn', 'click', (_) => createPlaylist());
    on('deletePlaylistBtn', 'click', (_) { final p=playlists.where((x)=>x['id']==activePlaylistId).firstOrNull;if(p!=null)deletePlaylist(p); });
    on('fileInput', 'change', (_) => importFiles());
    on('searchInput', 'input', (e) { query = (e.target as HTMLInputElement).value.toLowerCase(); renderList(); });
    on('sortSelect', 'change', (e) { sort = (e.target as HTMLSelectElement).value; renderList(); });
    on('playBtn', 'click', (_) => togglePlay()); on('miniPlay', 'click', (_) => togglePlay());
    on('prevBtn', 'click', (_) => previous()); on('miniPrev', 'click', (_) => previous()); on('nextBtn', 'click', (_) => next()); on('miniNext', 'click', (_) => next());
    on('backBtn', 'click', (_) => audio.currentTime = max(0, audio.currentTime - 10));
    on('forwardBtn', 'click', (_) => audio.currentTime = min(audio.duration, audio.currentTime + 10));
    on('shuffleBtn', 'click', (_) { shuffle = !shuffle; _syncButtons(); toast(shuffle ? 'シャッフルをオンにしました。' : 'シャッフルをオフにしました。'); });
    on('repeatBtn', 'click', (_) { repeat = repeat == 'off' ? 'one' : repeat == 'one' ? 'all' : 'off'; _syncButtons(); });
    on('timerBtn', 'click', (_) => openTimerSheet()); on('miniInfo', 'click', (_) => expandPlayer());
    on('miniPlayer', 'touchstart', (e) { final t=(e as TouchEvent).touches.item(0);if(t!=null)miniTouchStartY=t.clientY.toDouble(); });
    on('miniPlayer', 'touchend', (e) { final t=(e as TouchEvent).changedTouches.item(0);if(t!=null&&miniTouchStartY!=null&&miniTouchStartY!-t.clientY>35)expandPlayer();miniTouchStartY=null; });
    on('playerView', 'touchstart', (e) { final t=(e as TouchEvent).touches.item(0);playerSwipeCanCollapse=el<HTMLElement>('playerView').scrollTop<=1;if(t!=null)playerTouchStartY=t.clientY.toDouble(); });
    on('playerView', 'touchend', (e) { final t=(e as TouchEvent).changedTouches.item(0);if(playerSwipeCanCollapse&&t!=null&&playerTouchStartY!=null&&t.clientY-playerTouchStartY!>70)collapsePlayer();playerTouchStartY=null;playerSwipeCanCollapse=false; });
    on('sheetClose', 'click', (_) => closeSheet()); on('actionSheet', 'click', (e) { if(e.target==el<HTMLElement>('actionSheet'))closeSheet(); });
    on('sheetRename', 'click', (_) => sheetRename()); on('sheetExport', 'click', (_) { final r=sheetRecording;if(r!=null)exportOne(r);closeSheet(); });
    on('sheetShare', 'click', (_) { final r=sheetRecording;if(r!=null)exportOne(r,share:true);closeSheet(); });
    on('sheetDelete', 'click', (_) { final r=sheetRecording;closeSheet();if(r!=null)deleteRecording(r); });
    on('sheetRemoveFromPlaylist', 'click', (_) => removeSheetRecordingFromPlaylist());
    on('sheetNewPlaylist', 'click', (_) => createPlaylist(sheetRecording));
    on('timerSheetClose', 'click', (_) => closeTimerSheet());on('timerSheet', 'click', (e){if(e.target==el<HTMLElement>('timerSheet'))closeTimerSheet();});
    on('timerOff', 'click', (_) => setSleepMinutes(0));on('timer10', 'click', (_) => setSleepMinutes(10));on('timer20', 'click', (_) => setSleepMinutes(20));on('timer30', 'click', (_) => setSleepMinutes(30));on('timer60', 'click', (_) => setSleepMinutes(60));on('timerTrack', 'click', (_) => setSleepAfterTrack());
    on('customTimerApply', 'click', (_) { final m=el<HTMLInputElement>('customTimerMinutes').valueAsNumber;if(m.isFinite&&m>0)setSleepMinutes(m.round());else toast('1分以上の時間を入力してください。'); });
    on('seek', 'input', (e) { if (audio.duration.isFinite) audio.currentTime = (e.target as HTMLInputElement).valueAsNumber / 1000 * audio.duration; });
    on('persistBtn', 'click', (_) => requestPersistence()); on('exportMetaBtn', 'click', (_) => exportMetadata());
    on('exportAllBtn', 'click', (_) => exportAll()); on('deleteAllBtn', 'click', (_) => deleteAll());
    audio.addEventListener('timeupdate', ((Event _) => _syncPlayer()).toJS);
    audio.addEventListener('play', ((Event _) => _syncPlayer()).toJS);
    audio.addEventListener('pause', ((Event _) => _syncPlayer()).toJS);
    audio.addEventListener('ended', ((Event _) => onEnded()).toJS);
    audio.addEventListener('error', ((Event _) => toast('このファイルを再生できません。ファイルまたは形式を確認してください。')).toJS);
  }

  Future<void> reload() async {
    final raw = await bridgeList().toDart;
    recordings = (jsonDecode(raw.toDart) as List).map((e) => Recording(Map<String, dynamic>.from(e as Map))).toList();
    renderList();
  }

  Future<void> reloadPlaylists() async {
    final raw = await bridgeListPlaylists().toDart;
    playlists = (jsonDecode(raw.toDart) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    if (activePlaylistId != null && activePlaylistId != '__favorites__' && !playlists.any((p) => p['id'] == activePlaylistId)) activePlaylistId = null;
    renderPlaylists(); renderList();
  }

  List<Recording> get playQueue {
    if (activePlaylistId == '__favorites__') return recordings.where((r) => r.favorite).toList();
    final active = activePlaylistId == null ? null : playlists.where((p) => p['id'] == activePlaylistId).firstOrNull;
    if (active == null) return recordings;
    final ids = List<String>.from(active['recordingIds'] as List? ?? const []);
    return ids.map((id) => recordings.where((r) => r.id == id).firstOrNull).whereType<Recording>().toList();
  }

  List<Recording> get sortedPlayQueue {final list=playQueue.toList();list.sort((a,b)=>switch(sort){'new'=>b.createdAt.compareTo(a.createdAt),'title'=>a.title.compareTo(b.title),'duration'=>b.duration.compareTo(a.duration),_=>a.createdAt.compareTo(b.createdAt)});return list;}
  List<Recording> get playbackQueue {final resolved=playbackQueueIds.map((id)=>recordings.where((r)=>r.id==id).firstOrNull).whereType<Recording>().toList();return resolved.isEmpty?sortedPlayQueue:resolved;}

  void renderList() {
    final list = sortedPlayQueue.where((r) => r.title.toLowerCase().contains(query)).toList();
    final host = el<HTMLDivElement>('recordingList'); host.textContent = '';
    for (final r in list) {
      final item = HTMLDivElement()..className='recording-item';
      Timer? longPressTimer;double? pressX,pressY;var longPressed=false;
      item.addEventListener('touchstart',((TouchEvent e){final t=e.touches.item(0);if(t==null)return;pressX=t.clientX.toDouble();pressY=t.clientY.toDouble();longPressed=false;longPressTimer=Timer(const Duration(milliseconds:550),(){longPressed=true;openSheet(r);});}).toJS);
      item.addEventListener('touchmove',((TouchEvent e){final t=e.touches.item(0);if(t==null||pressX==null||pressY==null)return;if((t.clientX-pressX!).abs()>10||(t.clientY-pressY!).abs()>10)longPressTimer?.cancel();}).toJS);
      item.addEventListener('touchend',((TouchEvent _){longPressTimer?.cancel();if(longPressed)Timer(const Duration(milliseconds:450),()=>longPressed=false);}).toJS);
      item.addEventListener('touchcancel',((TouchEvent _){longPressTimer?.cancel();longPressed=false;}).toJS);
      item.addEventListener('click',((Event e){if(longPressed){e.preventDefault();e.stopPropagation();}}).toJS,true.toJS);
      item.addEventListener('contextmenu',((Event e){e.preventDefault();if(!longPressed)openSheet(r);}).toJS);
      final play = HTMLButtonElement()..className='item-play'..textContent=current?.id==r.id&&!audio.paused?'Ⅱ':'▶'..ariaLabel='${r.title}を再生'; play.addEventListener('click', ((Event _) { playSingle(r); }).toJS);
      final info = HTMLDivElement()..className='item-main';
      final title = document.createElement('strong')..textContent=r.title;
      final date = DateTime.tryParse(r.createdAt)?.toLocal();
      final detail = document.createElement('small')..textContent='${date == null ? '' : '${date.month}.${date.day}'}  ·  ${formatTime(r.duration)}  ·  ${formatBytes(r.size)}'; info.append(title); info.append(detail);
      final fav=HTMLButtonElement()..className='favorite ${r.favorite?'on':''}'..textContent=r.favorite?'★':'☆'..ariaLabel='お気に入り'; fav.addEventListener('click', ((Event _) { toggleFavorite(r); }).toJS);
      final more=HTMLButtonElement()..className='more'..textContent='⋮'..ariaLabel='その他'; more.addEventListener('click', ((Event _) { recordingMenu(r); }).toJS);
      item.append(play);item.append(info);item.append(fav);item.append(more);host.append(item);
    }
    el<HTMLDivElement>('emptyState').classList.toggle('hidden', list.isNotEmpty);
    el<HTMLElement>('settingsCount').textContent='${recordings.length}件';
  }

  void renderPlaylists() {
    final host = el<HTMLElement>('playlistTabs'); host.textContent = '';
    final all = HTMLButtonElement()..textContent = 'すべて (${recordings.length})'..className = activePlaylistId == null ? 'active' : '';
    all.addEventListener('click', ((Event _) { activePlaylistId = null; renderPlaylists(); renderList(); }).toJS); host.append(all);
    final favorites = HTMLButtonElement()..textContent = '★ お気に入り (${recordings.where((r)=>r.favorite).length})'..className = activePlaylistId == '__favorites__' ? 'active' : '';
    favorites.addEventListener('click', ((Event _) { activePlaylistId = '__favorites__'; renderPlaylists(); renderList(); }).toJS); host.append(favorites);
    for (final p in playlists) {
      final count = (p['recordingIds'] as List?)?.length ?? 0;
      final button = HTMLButtonElement()..textContent = '${p['name']} ($count)'..className = activePlaylistId == p['id'] ? 'active' : '';
      button.addEventListener('click', ((Event _) { activePlaylistId = p['id'] as String; renderPlaylists(); renderList(); }).toJS);
      button.addEventListener('dblclick', ((Event _) { deletePlaylist(p); }).toJS); host.append(button);
    }
    el<HTMLElement>('deletePlaylistBtn').classList.toggle('hidden', activePlaylistId == null || activePlaylistId == '__favorites__');
    el<HTMLElement>('playAllBtn').textContent = activePlaylistId == null ? '▶ すべて再生' : '▶ リストを再生';
  }

  void showView(String id) {
    for (final v in ['recordView','playerView','settingsView']) el<HTMLElement>(v).classList.add('hidden');
    el<HTMLElement>(id).classList.remove('hidden');
    el<HTMLElement>('recordFab').classList.add('hidden');
    el<HTMLElement>('app').classList.add('view-open');
  }
  void showLibrary(){for(final v in ['recordView','playerView','settingsView'])el<HTMLElement>(v).classList.add('hidden');el<HTMLElement>('recordFab').classList.remove('hidden');el<HTMLElement>('app').classList.remove('view-open');}
  void expandPlayer(){if(current==null)return;showView('playerView');if(!playerHistoryActive){window.history.pushState({'player':true}.jsify(),'','${window.location.pathname}${window.location.search}#player');playerHistoryActive=true;}}
  void collapsePlayer(){if(playerHistoryActive){window.history.back();}else{showLibrary();}}
  void closeRecord(){if(recorder!=null&&recorder!.state!='inactive'){toast('先に録音を保存またはキャンセルしてください。');return;}showLibrary();}

  Future<void> startRecording() async {
    if (capabilities['secure'] != true) { toast('マイクはHTTPSまたはlocalhostでのみ利用できます。'); return; }
    if (capabilities['media'] != true || capabilities['recorder'] != true) { toast('このブラウザは録音に対応していません。最新版のSafariまたはChromeをご利用ください。'); return; }
    try {
      final constraints = MediaStreamConstraints(audio: true.toJS);
      stream = await window.navigator.mediaDevices.getUserMedia(constraints).toDart;
      const candidates=['audio/mp4','audio/webm;codecs=opus','audio/webm','audio/ogg;codecs=opus'];
      final mime=candidates.where((type) => MediaRecorder.isTypeSupported(type)).firstOrNull ?? '';
      recorder = mime.isEmpty ? MediaRecorder(stream!) : MediaRecorder(stream!, MediaRecorderOptions(mimeType:mime,audioBitsPerSecond:128000));
      chunks.clear(); cancelling=false; paused=Duration.zero; pauseStarted=null; startedAt=DateTime.now();
      recorder!.ondataavailable = ((BlobEvent e) { if(e.data.size>0) chunks.add(e.data); }).toJS;
      recorder!.onstop = ((Event _) { finishRecording(); }).toJS;
      recorder!.start(2000);
      el<HTMLElement>('recordOrb').classList.add('active');el<HTMLElement>('recordState').textContent='録音中';el<HTMLElement>('recordActions').classList.remove('hidden');el<HTMLElement>('startInsideBtn').classList.add('hidden');
      recordTimer=Timer.periodic(const Duration(milliseconds:250),(_)=>updateRecordClock());
    } catch(e) { toast(micError(e.toString())); stopTracks(); }
  }

  void toggleRecordPause(){final r=recorder;if(r==null)return;if(r.state=='recording'){r.pause();pauseStarted=DateTime.now();el<HTMLElement>('recordState').textContent='一時停止中';el<HTMLElement>('pauseRecordBtn').textContent='▶';}else if(r.state=='paused'){r.resume();if(pauseStarted!=null)paused+=DateTime.now().difference(pauseStarted!);pauseStarted=null;el<HTMLElement>('recordState').textContent='録音中';el<HTMLElement>('pauseRecordBtn').textContent='Ⅱ';}}
  void stopRecording(){if(recorder?.state!='inactive')recorder!.stop();}
  void cancelRecording(){if(window.confirm('現在の録音をキャンセルしますか？録音は保存されません。')){cancelling=true;stopRecording();}}
  void updateRecordClock(){if(startedAt==null)return;var d=DateTime.now().difference(startedAt!)-paused;if(pauseStarted!=null)d-=DateTime.now().difference(pauseStarted!);el<HTMLElement>('recordTime').textContent=formatTime(d.inMilliseconds/1000);el<HTMLElement>('levelBar').style.width='${25+Random().nextInt(65)}%';}
  Future<void> finishRecording() async {
    recordTimer?.cancel();stopTracks();
    final duration=startedAt==null?0:(DateTime.now().difference(startedAt!)-paused-(pauseStarted==null?Duration.zero:DateTime.now().difference(pauseStarted!))).inMilliseconds/1000;
    final mime=recorder?.mimeType.isNotEmpty==true?recorder!.mimeType:(chunks.isNotEmpty?chunks.first.type:'audio/webm'); recorder=null;
    resetRecordUi(); if(cancelling||chunks.isEmpty){toast('録音をキャンセルしました。');return;}
    el<HTMLElement>('recordState').textContent='安全に保存しています…';
    try {final blob=Blob(chunks.toJS,BlobPropertyBag(type:mime));final now=DateTime.now();final id='${now.microsecondsSinceEpoch}-${Random().nextInt(9999)}';final ext=extensionFor(mime);final meta={'id':id,'title':'${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}-${two(now.minute)} 録音','createdAt':now.toUtc().toIso8601String(),'updatedAt':now.toUtc().toIso8601String(),'duration':duration,'mimeType':mime,'fileExtension':ext,'size':blob.size,'storageKey':'recording-$id.$ext','favorite':false,'playCount':0};await bridgeSave(jsonEncode(meta),blob).toDart;await reload();await refreshStorage();showLibrary();toast('録音を保存しました。タイトルはメニューから変更できます。');}catch(e){toast('保存できませんでした。空き容量を確認して、もう一度お試しください。');}finally{chunks.clear();}
  }
  void resetRecordUi(){el<HTMLElement>('recordOrb').classList.remove('active');el<HTMLElement>('recordState').textContent='録音の準備ができました';el<HTMLElement>('recordActions').classList.add('hidden');el<HTMLElement>('startInsideBtn').classList.remove('hidden');el<HTMLElement>('recordTime').textContent='00:00';el<HTMLElement>('levelBar').style.width='4%';}
  void stopTracks(){for(final t in stream?.getTracks().toDart??<MediaStreamTrack>[])t.stop();stream=null;}

  Future<void> playRecording(Recording r) async {if(current?.id==r.id&&audio.src.isNotEmpty){togglePlay();return;}try{final blob=await bridgeGetBlob(r.id).toDart;if(currentUrl.isNotEmpty)URL.revokeObjectURL(currentUrl);currentUrl=URL.createObjectURL(blob);current=r;audio.src=currentUrl;await audio.play().toDart;await bridgeUpdate(r.id,jsonEncode({'playCount':((r.data['playCount']as num?)?.toInt()??0)+1})).toDart;_updatePlayerMeta();_setMediaSession();renderList();}catch(e){toast('再生できませんでした。ファイルがないか、このブラウザでは対応していない形式です。');}}
  void playSingle(Recording r){singlePlayback=true;playbackQueueIds=[r.id];renderPlayerQueue();playRecording(r);}
  void togglePlay(){if(current==null){if(recordings.isNotEmpty)playRecording(recordings.first);return;}if(audio.paused){audio.play().toDart.then((_) {}, onError: (_) { toast('再生ボタンをもう一度押してください。'); });}else{audio.pause();}}
  void playAll(){final queue=sortedPlayQueue;if(queue.isEmpty){toast('再生するファイルがありません。');return;}singlePlayback=false;playbackQueueIds=queue.map((r)=>r.id).toList();repeat='off';_syncButtons();renderPlayerQueue();playRecording(queue.first);toast(activePlaylistId==null?'すべての録音を再生します。':'プレイリストを再生します。');}
  void next(){singlePlayback=false;if(playbackQueueIds.length<=1)playbackQueueIds=sortedPlayQueue.map((r)=>r.id).toList();final queue=playbackQueue;if(queue.isEmpty)return;final i=current==null?-1:queue.indexWhere((r)=>r.id==current!.id);final ni=shuffle&&queue.length>1?_randomOther(i,queue.length):i+1;if(ni>=queue.length){if(repeat=='all')playRecording(queue.first);else audio.pause();}else playRecording(queue[ni]);renderPlayerQueue();}
  void previous(){singlePlayback=false;if(audio.currentTime>4){audio.currentTime=0;return;}if(playbackQueueIds.length<=1)playbackQueueIds=sortedPlayQueue.map((r)=>r.id).toList();final queue=playbackQueue;if(queue.isEmpty)return;final i=queue.indexWhere((r)=>r.id==current?.id);if(i>0)playRecording(queue[i-1]);else if(repeat=='all')playRecording(queue.last);renderPlayerQueue();}
  int _randomOther(int i,int length){var n=i;while(n==i)n=Random().nextInt(length);return n;}
  void onEnded(){if(sleepAt!=null&&sleepAt!.millisecondsSinceEpoch==-1){clearSleep();return;}if(repeat=='one'&&current!=null){audio.currentTime=0;audio.play();}else if(singlePlayback){audio.pause();audio.currentTime=0;}else{next();}}
  void _syncPlayer(){final playing=!audio.paused;el<HTMLElement>('playBtn').textContent=playing?'Ⅱ':'▶';el<HTMLElement>('miniPlay').textContent=playing?'Ⅱ':'▶';final d=audio.duration.isFinite?audio.duration:current?.duration??0;el<HTMLElement>('currentTime').textContent=formatTime(audio.currentTime);el<HTMLElement>('totalTime').textContent=formatTime(d);el<HTMLElement>('miniTime').textContent='${formatTime(audio.currentTime)} / ${formatTime(d)}';final progress=d>0?(audio.currentTime/d*1000).clamp(0,1000):0;el<HTMLInputElement>('seek').value=progress.toString();el<HTMLElement>('miniProgress').style.width='${progress/10}%';}
  void _updatePlayerMeta(){final r=current;if(r==null)return;el<HTMLElement>('playerTitle').textContent=r.title;el<HTMLElement>('miniTitle').textContent=r.title;el<HTMLElement>('playerDate').textContent=r.createdAt.split('T').first;el<HTMLElement>('miniPlayer').classList.remove('hidden');el<HTMLElement>('app').classList.add('player-active');renderPlayerQueue();}
  void renderPlayerQueue(){final queue=playbackQueue;final host=el<HTMLElement>('playerQueue');host.textContent='';el<HTMLElement>('queueCount').textContent='${queue.length}曲';for(var i=0;i<queue.length;i++){final r=queue[i],isCurrent=r.id==current?.id;final button=HTMLButtonElement()..className='queue-item ${isCurrent?'current':''}';final number=document.createElement('span')..className='queue-number'..textContent='${i+1}';final info=HTMLDivElement();final title=document.createElement('strong')..textContent=r.title;final detail=document.createElement('small')..textContent=formatTime(r.duration);info.append(title);info.append(detail);final state=document.createElement('span')..className='queue-playing'..textContent=isCurrent?'♪':'';button.append(number);button.append(info);button.append(state);button.addEventListener('click',((Event _){singlePlayback=false;playRecording(r);}).toJS);host.append(button);}}
  void _syncButtons(){el<HTMLElement>('shuffleBtn').classList.toggle('active',shuffle);final b=el<HTMLElement>('repeatBtn');b.classList.toggle('active',repeat!='off');b.textContent=repeat=='one'?'↻¹':'↻';}

  Future<void> toggleFavorite(Recording r) async{await bridgeUpdate(r.id,jsonEncode({'favorite':!r.favorite})).toDart;await reload();renderPlaylists();}
  Future<void> createPlaylist([Recording? add]) async {final name=window.prompt('新しいプレイリスト名')?.trim();if(name==null||name.isEmpty)return;final now=DateTime.now();final row={'id':'playlist-${now.microsecondsSinceEpoch}','name':name,'recordingIds':add==null?<String>[]:<String>[add.id],'createdAt':now.toUtc().toIso8601String()};await bridgeSavePlaylist(jsonEncode(row)).toDart;if(add==null)activePlaylistId=row['id'] as String;await reloadPlaylists();if(add!=null)openSheet(add);toast('プレイリスト「$name」を作成しました。');}
  Future<void> addToPlaylist(Recording r) async {if(playlists.isEmpty){await createPlaylist();if(playlists.isEmpty)return;}final names=playlists.map((p)=>p['name']).join(' / ');final name=window.prompt('追加先を入力してください：$names',playlists.first['name'] as String)?.trim();final p=playlists.where((x)=>x['name']==name).firstOrNull;if(p==null){toast('プレイリストが見つかりません。');return;}final ids=List<String>.from(p['recordingIds'] as List? ?? const []);if(!ids.contains(r.id))ids.add(r.id);p['recordingIds']=ids;await bridgeSavePlaylist(jsonEncode(p)).toDart;await reloadPlaylists();toast('「${p['name']}」に追加しました。');}
  Future<void> deletePlaylist(Map<String,dynamic> p) async {if(!window.confirm('プレイリスト「${p['name']}」を削除しますか？録音ファイルは削除されません。'))return;await bridgeRemovePlaylist(p['id'] as String).toDart;activePlaylistId=null;await reloadPlaylists();}
  Future<void> deleteRecording(Recording r) async {if(!window.confirm('「${r.title}」を削除しますか？この操作は元に戻せません。'))return;await bridgeRemove(r.id).toDart;playbackQueueIds.remove(r.id);for(final p in playlists){final ids=List<String>.from(p['recordingIds'] as List? ?? const [])..remove(r.id);p['recordingIds']=ids;await bridgeSavePlaylist(jsonEncode(p)).toDart;}if(current?.id==r.id){audio.pause();audio.removeAttribute('src');current=null;el<HTMLElement>('miniPlayer').classList.add('hidden');el<HTMLElement>('app').classList.remove('player-active');}await reload();await reloadPlaylists();renderPlayerQueue();await refreshStorage();toast('削除しました。');}
  void recordingMenu(Recording r) => openSheet(r);
  void openSheet(Recording r){sheetRecording=r;el<HTMLElement>('sheetTitle').textContent=r.title;final host=el<HTMLElement>('sheetPlaylistChoices');host.textContent='';for(final p in playlists){final ids=List<String>.from(p['recordingIds'] as List? ?? const []);final button=HTMLButtonElement()..textContent=p['name'] as String..className=ids.contains(r.id)?'added':'';button.addEventListener('click',((Event _){toggleSheetPlaylist(p,r);}).toJS);host.append(button);}el<HTMLElement>('sheetRemoveFromPlaylist').classList.toggle('hidden',activePlaylistId==null||activePlaylistId=='__favorites__');el<HTMLElement>('actionSheet').classList.remove('hidden');}
  void closeSheet(){el<HTMLElement>('actionSheet').classList.add('hidden');sheetRecording=null;}
  void sheetTouchStart(Event event){final t=(event as TouchEvent).touches.item(0);if(t!=null)sheetTouchStartY=t.clientY.toDouble();}
  void sheetTouchEnd(Event event){final t=(event as TouchEvent).changedTouches.item(0);if(t!=null&&sheetTouchStartY!=null&&t.clientY-sheetTouchStartY!>55){if(!el<HTMLElement>('actionSheet').classList.contains('hidden'))closeSheet();if(!el<HTMLElement>('timerSheet').classList.contains('hidden'))closeTimerSheet();}sheetTouchStartY=null;}
  Future<void> toggleSheetPlaylist(Map<String,dynamic> p,Recording r)async{final ids=List<String>.from(p['recordingIds'] as List? ?? const []);final added=ids.contains(r.id);if(added){ids.remove(r.id);}else{ids.add(r.id);}p['recordingIds']=ids;await bridgeSavePlaylist(jsonEncode(p)).toDart;await reloadPlaylists();openSheet(r);toast(added?'プレイリストから外しました。':'プレイリストに追加しました。');}
  Future<void> sheetRename()async{final r=sheetRecording;if(r==null)return;final name=window.prompt('新しいタイトル',r.title)?.trim();if(name==null||name.isEmpty)return;await bridgeUpdate(r.id,jsonEncode({'title':name})).toDart;await reload();final updated=recordings.firstWhere((x)=>x.id==r.id);if(current?.id==r.id){current=updated;_updatePlayerMeta();}openSheet(updated);}
  Future<void> removeSheetRecordingFromPlaylist()async{final r=sheetRecording;if(r==null||activePlaylistId==null||activePlaylistId=='__favorites__')return;final p=playlists.firstWhere((x)=>x['id']==activePlaylistId);final ids=List<String>.from(p['recordingIds'] as List? ?? const [])..remove(r.id);p['recordingIds']=ids;await bridgeSavePlaylist(jsonEncode(p)).toDart;closeSheet();await reloadPlaylists();toast('プレイリストから外しました。');}
  Future<void> exportOne(Recording r,{bool share=false})async{try{final blob=await bridgeGetBlob(r.id).toDart;final name='${safeName(r.title)}.${r.extension}';final shared=share ? (await bridgeShare(blob,name,r.title).toDart).toDart : false;if(shared){return;}bridgeDownload(blob,name);}catch(e){toast('ファイルを書き出せませんでした。');}}
  Future<void> importFiles()async{final input=el<HTMLInputElement>('fileInput');final files=input.files;if(files==null)return;for(var i=0;i<files.length;i++){final f=files.item(i);if(f==null)continue;try{final now=DateTime.now(),id='import-${now.microsecondsSinceEpoch}-$i';final ext=f.name.contains('.')?f.name.split('.').last.toLowerCase():extensionFor(f.type);final meta={'id':id,'title':f.name.replaceFirst(RegExp(r'\.[^.]+$'),''),'createdAt':now.toUtc().toIso8601String(),'updatedAt':now.toUtc().toIso8601String(),'duration':0,'mimeType':f.type.isEmpty?'audio/$ext':f.type,'fileExtension':ext,'size':f.size,'storageKey':'recording-$id.$ext','favorite':false,'playCount':0};await bridgeSave(jsonEncode(meta),f).toDart;}catch(_){toast('${f.name}を読み込めませんでした。');}}input.value='';await reload();await refreshStorage();toast('ファイルを読み込みました。');}

  Future<void> refreshStorage()async{try{final e=jsonDecode((await bridgeEstimate().toDart).toDart)as Map<String,dynamic>;final total=recordings.fold<int>(0,(s,r)=>s+r.size);final quota=(e['quota']as num?)?.toInt()??0,usage=(e['usage']as num?)?.toInt()??0;el<HTMLElement>('storageSummary').textContent='${recordings.length}件 · ${formatBytes(total)}';el<HTMLElement>('settingsUsage').textContent=formatBytes(total);el<HTMLElement>('settingsFree').textContent=quota>0?formatBytes(max(0,quota-usage)):'不明';el<HTMLElement>('persistState').textContent=e['persisted']==true?'保存が許可されています':'保証されていません';el<HTMLElement>('storageBar').style.width=quota>0?'${(usage/quota*100).clamp(2,100)}%':'2%';}catch(_){el<HTMLElement>('storageSummary').textContent='${recordings.length}件';}}
  Future<void> requestPersistence()async{final ok=(await bridgePersist().toDart).toDart;toast(ok?'ブラウザが永続保存を許可しました。':'永続保存は許可されませんでした。ファイルのバックアップをおすすめします。');await refreshStorage();}
  void exportMetadata(){final blob=Blob([jsonEncode(recordings.map((r)=>r.data).toList()).toJS].toJS,BlobPropertyBag(type:'application/json'));bridgeDownload(blob,'song-pocket-backup-${DateTime.now().toIso8601String().split('T').first}.json');}
  Future<void> exportAll()async{if(recordings.isEmpty){toast('書き出すファイルがありません。');return;}toast('ファイルごとに保存確認が複数回表示される場合があります。');for(final r in recordings){await exportOne(r);await Future<void>.delayed(const Duration(milliseconds:400));}}
  Future<void> deleteAll()async{if(!window.confirm('すべての録音と情報を削除しますか？先に大切なファイルをバックアップしてください。'))return;if(window.prompt('削除するには「すべて削除」と入力してください。')!='すべて削除')return;audio.pause();await bridgeClear().toDart;current=null;el<HTMLElement>('miniPlayer').classList.add('hidden');el<HTMLElement>('app').classList.remove('player-active');playlists=[];activePlaylistId=null;await reload();await reloadPlaylists();await refreshStorage();toast('すべてのデータを削除しました。');}
  void openTimerSheet(){el<HTMLElement>('timerSheet').classList.remove('hidden');}
  void closeTimerSheet(){el<HTMLElement>('timerSheet').classList.add('hidden');}
  void setSleepAfterTrack(){clearSleep(show:false);sleepAt=DateTime.fromMillisecondsSinceEpoch(-1);el<HTMLElement>('timerBtn').textContent='◷ この曲の終了後に停止';closeTimerSheet();}
  void setSleepMinutes(int minutes){clearSleep(show:false);closeTimerSheet();if(minutes<=0){toast('スリープタイマーをオフにしました。');return;}sleepAt=DateTime.now().add(Duration(minutes:minutes));sleepTimer=Timer.periodic(const Duration(seconds:1),(_){final left=sleepAt!.difference(DateTime.now());if(left<=Duration.zero){audio.pause();clearSleep();toast('スリープタイマーで再生を停止しました。');}else el<HTMLElement>('timerBtn').textContent='◷ 終了まで ${left.inMinutes}:${two(left.inSeconds%60)}';});toast('$minutes分後に再生を停止します。');}
  void clearSleep({bool show=true}){sleepTimer?.cancel();sleepTimer=null;sleepAt=null;el<HTMLElement>('timerBtn').textContent='◷ スリープタイマー：オフ';if(show)audio.pause();}
  void _renderCompatibility(){final rows={'安全な接続':capabilities['secure'],'マイク録音':capabilities['media']==true&&capabilities['recorder']==true,'ローカルDB':capabilities['indexedDb'],'高度なファイル保存':capabilities['opfs'],'ロック画面操作':capabilities['mediaSession']};el<HTMLElement>('compatDetails').textContent=rows.entries.map((e)=>'${e.value==true?'✓':'△'} ${e.key}').join('\n');final problems=<String>[];if(capabilities['secure']!=true)problems.add('HTTPSではないためマイクを利用できません。');if(capabilities['recorder']!=true)problems.add('このブラウザは録音に対応していません。');if(problems.isNotEmpty){final n=el<HTMLElement>('compatNotice');n.textContent=problems.join(' ');n.classList.remove('hidden');}}
  void _setMediaSession(){try{window.navigator.mediaSession.metadata=MediaMetadata(MediaMetadataInit(title:current!.title,artist:'うたポケット'));window.navigator.mediaSession.setActionHandler('play',((JSAny? _)=>audio.play()).toJS);window.navigator.mediaSession.setActionHandler('pause',((JSAny? _)=>audio.pause()).toJS);window.navigator.mediaSession.setActionHandler('nexttrack',((JSAny? _)=>next()).toJS);window.navigator.mediaSession.setActionHandler('previoustrack',((JSAny? _)=>previous()).toJS);}catch(_){}}
  void toast(String text){final t=el<HTMLElement>('toast');t.textContent=text;t.classList.add('show');Timer(const Duration(seconds:3),()=>t.classList.remove('show'));}
}

String two(int n)=>n.toString().padLeft(2,'0');
String formatTime(num seconds){if(!seconds.isFinite||seconds<0)return'0:00';final s=seconds.floor();return s>=3600?'${s~/3600}:${two((s%3600)~/60)}:${two(s%60)}':'${s~/60}:${two(s%60)}';}
String formatBytes(int n){if(n<1024)return'$n B';if(n<1048576)return'${(n/1024).toStringAsFixed(1)} KB';if(n<1073741824)return'${(n/1048576).toStringAsFixed(1)} MB';return'${(n/1073741824).toStringAsFixed(1)} GB';}
String extensionFor(String mime){if(mime.contains('mp4'))return'm4a';if(mime.contains('ogg'))return'ogg';if(mime.contains('mpeg'))return'mp3';if(mime.contains('wav'))return'wav';return'webm';}
String safeName(String s)=>s.replaceAll(RegExp(r'[\\/:*?"<>|]'),'_');
String micError(String e){if(e.contains('NotAllowed'))return'マイクの使用が拒否されました。ブラウザのサイト設定でマイクを許可してください。';if(e.contains('NotFound'))return'利用できるマイクが見つかりません。';if(e.contains('NotReadable'))return'ほかのアプリがマイクを使用している可能性があります。';return'マイクを開始できませんでした。権限と接続状態を確認してください。';}

void main()=>App().init();
