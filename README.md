# 노래 주머니

`mobile_audio_recorder_player_agent_spec.md`를 바탕으로 만든 Dart 기반 로컬 우선 모바일 녹음·재생 PWA입니다.

## 개발 실행

```bash
dart pub get
dart compile js web/main.dart -O2 -o web/main.dart.js
cd web
python3 -m http.server 8080
```

브라우저에서 `http://localhost:8080`을 엽니다. 스마트폰 실기기에서는 GitHub Pages, Netlify 같은 HTTPS 정적 호스팅에 `web/` 폴더의 내용을 배포해야 마이크를 사용할 수 있습니다.

## 데이터 저장

- 메타데이터: IndexedDB `song-pocket/recordings`
- 오디오: OPFS `recordings/` 우선
- OPFS 미지원 또는 쓰기 실패 시: IndexedDB Blob
- Service Worker: 앱 셸만 캐시하며 녹음 파일은 캐시하지 않음

브라우저 데이터 삭제 시 로컬 녹음도 삭제될 수 있습니다. 중요한 녹음은 앱의 개별 내보내기 또는 전체 파일 내보내기를 이용해 별도로 보관하세요.
