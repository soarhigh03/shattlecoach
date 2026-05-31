# frontend/lib/ml — ShattleCoach on-device ML (Dart)

폰 안에서만 도는 배드민턴 스윙 분석 라이브러리. **서버 없이** 한 번의 호출로
포즈 추출 → 폼 채점 → 임팩트 주석 → 코칭까지 끝냅니다. (Flutter / Android · iOS)

코칭 문장 자체는 룰북에서 결정론적으로 나오고, **선택적으로** Groq LLM이 그 문장들을
자연스러운 한 단락으로 *다듬기만* 합니다(새 내용·숫자·조언 추가 금지). LLM 키는 빌드 시
(`--dart-define=GROQ_API_KEY=...`)로 주입하거나 `frontend/.env`의 `GROQ_API_KEY`로
런타임에 들어옵니다. 키가 없거나 오프라인이면 룰북 원문으로 자동 fallback —
즉 **인터넷·키 없이도 코칭은 항상 동작**합니다.

이 문서는 라이브러리 코드가 **무엇인지** 설명합니다. 호출 지점은
`features/ai_coach/ai_coach_screen.dart`를 참고하세요.

## 공개 API

```dart
import 'package:shattlecoach/ml/shattle_ml.dart'; // 또는 상대경로

final ShattleScore s = await ShattleMl.analyzeSwing(
  videoPath: path,        // 분석할 클립 경로
  stroke: 'high_clear',   // 사용자가 고른 동작 (kShattleStrokes 중 하나)
  startMs: 1200,          // (선택) trim 시작 — 분석 범위 제한
  endMs:   4800,          // (선택) trim 끝
  onStatus: (msg) {},     // (선택) 진행 상태 콜백
);
// s.postureStars / s.speedStars / s.stepStars  (평가되는 축만 non-null)
// s.positives  (잘한 점)   s.coachingParagraph  (코칭)
// s.annotatedImpactPngBase64  (임팩트 자세 사진, base64 PNG)
```
`ShattleMl.warmUp()`으로 에셋을 미리 로드해 둘 수 있습니다(선택).

## 모듈 구성 (`lib/`)

| 파일 | 역할 |
|---|---|
| `shattle_ml.dart` | **진입점.** 전체 파이프라인 + `ShattleScore` 결과 타입 |
| `pose_extractor.dart` | 영상→프레임(네이티브 채널)→MoveNet(TFLite)→17 COCO 키포인트 |
| `rule_scorer.dart` | 자세 4기준(C1 타점·C2 팔꿈치·C3 허리회전·C4 무릎) 기하 채점 |
| `rule_calibration.dart` | 동작별(per-class) 임계값으로 자세 재채점 |
| `speed_step_scorer.dart` | 스윙 속도·풋워크 별점(BST 퍼센타일) |
| `axis_filter.dart` | 동작에 무관한 축 제거(서브=자세만 등) |
| `rulebook_tips.dart` | 코칭 문장 선택(변형 포함) + "잘한 점" + 결정론적 한 단락 |
| `impact_annotator.dart` | 임팩트 프레임에 원·화살표·한국어 라벨(동작별) → base64 PNG |

## 데이터 흐름

```
영상 + 사용자 선택 동작
  → extractPose (MoveNet INT8)            # ST-GCN 분류기/OOD 안 씀 (사용자가 동작 선택)
  → scoreRules → RuleCalibration.apply    # 자세 4기준, 동작별 임계값
  → scoreSpeed / scoreStep                # 별점
  → AxisFilter.apply                      # 무관 축 키 제거
  → annotateImpactOffline                 # 임팩트 주석 PNG
  → composeCoaching                       # 룰북 문장 선택 → 결정론적 한 단락
  → (선택) GroqCoach.smooth               # LLM이 그 문장들을 자연스럽게 잇기만 함(가드레일)
  → ShattleScore
```

## 에셋 (`frontend/assets/`)

`movenet_lightning_int8.tflite`(포즈, INT8 2.9MB), `bst_speed_percentiles.json`,
`bst_step_percentiles.json`, `rule_calibration.json`(동작별 임계값),
`stroke_axes.json`(동작별 평가 축), `rulebook_tips.json`(코칭 문장 뱅크).
런타임에 `assets/<name>` 경로로 로드됩니다 (pubspec에 개별 등록).

## 네이티브 채널

`MethodChannel('com.shattlecoach/frame_extractor')` — 영상에서 프레임을 ms 단위로
뽑는 두 메서드(`getFrame`, `getDurationMs`)를 expose:

- **Android**: `frontend/android/app/src/main/kotlin/com/mca/shattlecoach/MainActivity.kt`
  (`MediaMetadataRetriever`)
- **iOS**: `frontend/ios/Runner/FrameExtractor.swift`
  (`AVAssetImageGenerator`, 50ms tolerance)

## 코칭 문구의 출처 / 수정 방법

코칭 문장은 LLM이 만드는 게 아니라 **룰북 뱅크에서 결정론적으로** 나옵니다.
원천은 `data/coaching_knowledge.json`(동작×기준 연구 자료) → `backend/scripts/gen_rulebook_tips.py`
가 변형 문장을 더해 `rulebook_tips.json`을 생성합니다. **문구를 고치려면 coaching_knowledge.json
수정 후 생성기를 다시 돌리세요.**

## 설계 메모
- 자세는 **4기준**. 5번째였던 "머리 안정"(nose_y 표준편차)은 카메라 거리에 취약해 제거.
- ST-GCN 동작 분류기는 실제 폰 영상을 전부 OOD 처리해 **우회**(사용자가 동작 선택). 관련 ONNX/OOD 에셋 없음.
- 자세 채점은 신경망이 아니라 순수 기하 + 임계값. 포즈 추출(MoveNet)만 INT8 양자화됨.
- LLM(Groq `llama-3.1-8b-instant`)은 **문장 다듬기 전용**. 룰북이 고른 문장만 잇고, 가드레일
  (금칙어 검사)로 새 조언을 막음. 키는 빌드 시 `--dart-define=GROQ_API_KEY=...`로 주입하거나
  `frontend/.env`의 `GROQ_API_KEY`로 런타임에 들어옴(둘 다 gitignored / repo 미포함).
  `analyzeSwing(enableLlm: false)`로 끌 수 있음.
