# RunTime

<p align="center">
  <img src="assets/runtime-run.gif" width="252" alt="메뉴바에서 달리는 RunTime 러너들">
</p>

Claude Code를 쓰는 만큼 macOS 메뉴바의 러너가 빨리 달립니다.
러너를 누르면 5시간 세션과 주간 사용률이 나와서, `/usage`를 치지 않아도 한도가 얼마나 남았는지 알 수 있습니다.

<p align="center">
  <img src="assets/readme-usage.png" width="260" alt="사용량 창: 무대에서 달리는 러너, 세션 42%, 주간 18%, 최근 30분 그래프">
  <img src="assets/readme-shop.png" width="260" alt="상점: 행운 상자, 오늘의 특가, 트랙 목록">
  <img src="assets/readme-quests.png" width="260" alt="퀘스트: 러너 레벨, 출석, 오늘의 미션">
</p>

- 사용률은 Claude가 알려 주는 공식 값이라 웹과 데스크톱 앱에서 쓴 양도 들어갑니다.
- 80%, 95%에 닿으면 러너가 지치고 알림이 옵니다.
- 러너 28종, 내 그림, [Petdex](https://petdex.dev) 펫 가운데 골라 달립니다.
- 무대에서 장애물 피하기 미니게임을 하고, 모은 코인으로 트랙·날씨·꼬리 같은 꾸미기를 삽니다.
- Claude Code가 대답을 마치면 러너가 알려 줍니다.

Anthropic이 만든 앱이 아닌 개인 프로젝트입니다.

## 설치

macOS 13 이상, Claude Code에 로그인한 상태, Swift 6.0 이상(Xcode 16 또는 Command Line Tools 16 이상)이 필요합니다.
Swift가 없으면 먼저 `xcode-select --install`을 실행하세요. Xcode와 Command Line Tools가 함께 있으면 Swift가 더 새것인 쪽으로 빌드하고, 너무 오래됐거나 Xcode 약관에 동의하지 않았으면 무엇을 하면 되는지 알려 주고 멈춥니다. Xcode를 업데이트한 뒤에는 이전 빌드 결과를 비우고 다시 빌드합니다.

```bash
git clone https://github.com/youminki/RunTime.git
cd RunTime
./install.sh
```

내 Mac에서 직접 빌드해 응용 프로그램 폴더에 넣고 바로 실행합니다. 빌드는 1~2분 걸립니다.
직접 빌드한 앱이라 "확인되지 않은 개발자" 경고는 뜨지 않습니다.

처음 한 번은 아래 창이 뜹니다.

| 창 | 누를 것 | 이유 |
| --- | --- | --- |
| 서명 인증서를 신뢰할지 묻는 로그인 암호 | 암호 입력 | 앱을 다시 빌드해도 키체인 허용이 풀리지 않게 서명용 인증서를 한 번 만듭니다 |
| "security가 키체인에 접근하려고 합니다" | **항상 허용** | Claude Code의 로그인 토큰으로 사용량을 조회합니다. "허용"만 누르면 다음에 또 묻습니다 |
| 알림 허용 | 허용 | 80%, 95% 알림에 씁니다 |

클론한 폴더는 지우지 마세요. 앱 안에서 업데이트할 때 이 폴더에서 다시 빌드합니다.

## 쓰는 법

| 하고 싶은 것 | 방법 |
| --- | --- |
| 사용량 보기 | 메뉴바 러너를 누르거나 ⌃⌥U |
| 일별 사용량, 순위, 설정 | 러너를 오른쪽 클릭 |
| 업무 일지, 일일보고·주간 보고·레드마인 댓글 복사 | 러너를 오른쪽 클릭하고 "업무 일지" |
| 피그마 화면설계서에서 바뀐 화면 보기 | 앱 창 왼쪽 "디자인"(⌘6), 또는 러너를 오른쪽 클릭하고 "디자인 변경" |
| 마크업할 화면 하나만 가져오기 | 피그마에서 화면을 "링크 복사"하고 디자인 화면의 🔗(⇧⌘V) |
| /etc/hosts 켜고 끄기, 정리, 백업 | 앱 창 왼쪽 "호스트"(⌘7), 또는 러너를 오른쪽 클릭하고 "호스트"에서 묶음을 바로 켜고 끄기. 저장할 때 관리자 암호를 묻습니다 |
| Claude 계정 바꾸기 | 러너를 오른쪽 클릭하고 "Claude 계정". 다른 계정은 Claude Code에서 `/login` 하면 저절로 추가되고, 설정 > 사용량에서 한도에 막히면 바로 다른 계정으로 바꾸게 할 수 있습니다 |
| 러너 바꾸기 | 사용량 창에서 러너 이름(`고양이 ›`)을 누르고 러너 탭 |
| 미니게임 | 무대 오른쪽 위 "게임". 스페이스·클릭으로 점프(길게 누르면 높이), ↓로 숙이기 |
| 꾸미기 사기·쓰기 | 러너 이름을 누르고 상점·창고 탭 |

러너는 최근 1분 동안 쓴 토큰 양에 맞춰 걷고, 달리고, 질주합니다. 5분 넘게 쓰지 않으면 잡니다.

<p align="center">
  <img src="assets/runtime-game.gif" width="344" alt="미니게임: 고스트와 겨루며 무지개 꼬리를 단 고양이가 장애물을 넘는다">
</p>

<p align="center">
  <img src="assets/readme-storage.png" width="260" alt="창고: 산 트랙과 꼬리를 쓴 모습으로 보여 준다">
</p>

화면마다 자세한 설명은 [자세한 사용법](docs/guide.md)에 있습니다.

## 업데이트

앱이 30분마다, 그리고 매일 오전 9시에 GitHub에서 새 버전을 확인합니다. 자동으로 받지 못한 새 버전이 있으면 러너가 말풍선으로 알려 주고, 말풍선을 누르면 바로 업데이트합니다. 자동 업데이트는 조용히 하고, 말풍선을 눌러 설치할 때는 진행률과 남은 시간이 나옵니다. 업데이트를 마치면 러너 아래 말풍선에 새 기능, 고친 점, 다듬은 점을 패치노트로 보여 주고, 닫을 때까지 남겨 둡니다.
설정 > 일반 > 업데이트에서 "업데이트"를 누르거나 "자동으로 업데이트"를 켜 두면, 클론한 폴더에서 새 코드를 받아 다시 빌드합니다.
1~2분 동안 러너가 사라졌다가 새 버전으로 나타납니다.
클론에서 다른 브랜치로 일하거나 커밋하지 않은 변경이 있으면, 그 폴더는 건드리지 않고 같은 저장소의 업데이트 전용 폴더(`~/Library/Application Support/RunTime/update-source`)에서 GitHub 최신을 빌드해 설치합니다. 빌드가 실패하면 쓰던 앱이 그대로 남고, 로그는 `~/Library/Logs/RunTime/update.log`에 있습니다.

버전은 `VERSION`의 주.부 번호에 그 뒤 쌓인 커밋 수를 붙여 커밋마다 오릅니다(예: 0.8.3). 큰 변경 때만 `VERSION`을 올립니다.
터미널에서 하려면 클론한 폴더에서 `git pull --ff-only && ./install.sh`를 실행하세요. 달라진 점은 [변경 기록](CHANGELOG.md)에 있습니다.

## 지우기

응용 프로그램 폴더에서 `RunTime.app`을 지웁니다. 설정과 기록까지 지우려면 아래도 실행하세요.

```bash
defaults delete dev.runtime.RunTime
rm -rf ~/Library/Application\ Support/RunTime ~/Library/Logs/RunTime
```

## 자주 묻는 것

**키체인 암호를 계속 물어요.**
창이 뜰 때 "허용" 대신 "항상 허용"을 누르세요. `~/.claude/.credentials.json` 파일이 있으면 키체인보다 그 파일을 먼저 읽어서 창이 뜨지 않습니다.
레드마인 키·팀즈 웹훅을 예전 버전에서 저장했다면, 새 버전이 처음 읽을 때 한 번 더 묻고 업데이트해도 묻지 않는 항목으로 옮깁니다.

**메뉴바에서 러너가 안 보여요.**
화면이 좁고 앞에 있는 앱의 메뉴가 길면 macOS가 메뉴바 항목을 왼쪽부터 « 안으로 숨깁니다.
install.sh는 처음 설치할 때 러너를 오른쪽 끝에 두어 가장 늦게 숨게 합니다. 그래도 숨으면 ⌘를 누른 채
러너를 « 단추 오른쪽으로 끌어 두세요. macOS가 그 자리를 기억하고, 업데이트해도 옮기지 않습니다.

**`/usage`와 숫자가 달라요.**
공식 값은 3분마다 받아서 최대 3분까지 늦을 수 있습니다. 사용량 창을 열거나 ↻를 누르면 바로 다시 받습니다.

**예전 이름 TokenCat으로 설치했어요.**
업데이트하거나 `./install.sh`를 다시 실행하면 옛 앱을 지우고 `RunTime.app`을 설치합니다.
설정, 최고 점수, 순위 참여 정보, 내 러너와 받은 펫, 로그인 시 자동 시작은 새 앱이 처음 켜질 때 옮겨 옵니다.
알림 허용은 한 번 더 묻습니다. 옛 설정(`dev.tokencat.TokenCat`)은 지우지 않으니 필요 없으면
`defaults delete dev.tokencat.TokenCat`로 지우세요.

## 무엇을 어디로 보내나

| 보내는 곳 | 언제 | 보내는 것 |
| --- | --- | --- |
| Anthropic | 3분마다 | Claude Code 로그인 토큰으로 사용률 조회 |
| Anthropic | Claude 계정이 둘 이상일 때 10분마다, 토큰이 바뀌었을 때 | 저장해 둔 다른 계정 토큰으로 사용률 조회, 토큰이 어느 계정 것인지 확인, 다른 계정 토큰이 만료되기 전에 리프레시 토큰으로 새로 받기 |
| 순위 서버 | 순위에 참여했을 때 | 무작위 설치 ID, 닉네임, 그리고 최근 7일 기록을 넘은 판의 점수, 코인 수, 플레이 시간, 앱 버전 |
| 순위 서버 | 순위에 참여해 최고 기록을 올렸을 때 | 그 판의 고스트 (씨앗, 키 입력 기록, 러너 이름). 내 그림 러너는 이름을 보내지 않음 |
| 순위 서버 | 사용량 창이나 앱 창 게임 화면이 열려 있을 때 30초마다, 참여 중이면 10분마다 | 참여 전에는 없음 (공개 순위만 받음). 참여 중에는 내 순위를 알려고 설치 ID를 함께 보냄 |
| petdex.dev | Petdex에서 찾기를 열었을 때 | 없음 (펫 목록과 그림만 받음) |
| GitHub | 30분마다, 매일 오전 9시 | 없음 (공개 저장소의 커밋 비교만 받음) |
| Figma | 디자인 변경 기록에 화면설계서를 더했을 때, 프로젝트의 가져오기를 눌렀을 때, 주기를 정한 프로젝트는 그 주기마다, 상세에서 화면을 볼 때, 날짜 비교에서 버전 비교를 눌렀을 때 | 없음 (내 토큰으로 파일 정보, 버전 기록, 그 버전의 화면 노드, 프레임 이미지만 받음). 받은 내용은 이 Mac에만 저장 |

로그인 토큰은 Anthropic 말고는 어디에도 보내지 않으며 파일이나 로그에 남기지 않습니다.
Claude 계정을 바꿀 수 있게 Claude Code에 로그인했던 계정마다 로그인 정보를 이 Mac 키체인의 "RunTime Claude account" 항목에 두고,
계정을 바꿀 때만 Claude Code의 키체인 항목과 `~/.claude.json`의 계정 정보를 고칩니다.
키체인을 자동으로 열거나 Mac 암호를 저장하지는 않습니다.

## 한계

- 사용률은 Anthropic이 공식으로 안내하지 않은 방식으로 받습니다. 이 방식이 바뀌거나 막히면 사용률은 `--`로 비고 속도와 오늘 사용량만 보입니다.
- 키체인은 Apple의 `/usr/bin/security`로 읽습니다. 그래서 다시 빌드해도 다시 묻지 않지만,
  "항상 허용"을 누른 뒤에는 다른 프로그램도 같은 방법으로 이 토큰을 읽을 수 있습니다.
  계정 전환용으로 저장한 다른 계정의 토큰("RunTime Claude account" 항목)도 같은 방법으로 만들어서, 같은 조건이면 읽을 수 있습니다.
- 계정을 바꾸면 Claude Code가 `~/.claude.json`을 쓰는 순간과 겹칠 때 그 파일의 다른 변경 하나가 사라질 수 있습니다. 쓰는 시간을 짧게 해 두었지만 완전히 막지는 못합니다.
- Agent SDK나 `claude -p`로 쓴 양은 한도가 따로라서 기록에 SDK 표시가 있으면 따로 보여 줍니다. 표시가 확실하지 않아 추정입니다.
- 움직임이 많은 Petdex 펫은 메뉴바 칸(30px 안팎)에서 뭉개져 보일 수 있습니다.

## 개발

```bash
swift run RunTime             # 빌드하지 않은 채 개발 실행 (알림과 자동 시작은 동작하지 않음)
./scripts/test.sh             # 테스트
./scripts/check-typecheck.sh  # 타입 추론이 300ms 넘는 식 찾기 (Xcode 16 컴파일러에서 빌드가 멈추는 식)
python3 -I scripts/check-symbols.py   # macOS 13에 없는 SF Symbol 찾기
scripts/build-app.sh          # dist/RunTime.app과 dmg 만들기
python3 -I scripts/update-prices.py   # Claude 모델 단가를 LiteLLM 가격 데이터에서 다시 받아 PricingData.swift 만들기
python3 -I scripts/update-aliases.py  # Petdex 캐릭터의 한국어 이름을 Wikidata에서 받아 한글 검색 사전 만들기 (30분쯤)
```

설계 결정, 측정값, 트러블슈팅 기록은 [개발 기록](docs/development.md)에 모았습니다.

<details>
<summary>점검용 실행 옵션과 순위 서버</summary>

`.build/debug/RunTime` 뒤에 붙여 실행합니다.

| 옵션 | 하는 일 |
| --- | --- |
| `--report` | 집계를 ccusage와 비교 |
| `--worklog <명령>` | 업무 일지를 보고서 글로 받거나 줄을 넣기 (`--worklog`만 치면 명령 목록). `RUNTIME_WORKLOG`로 다른 파일을 쓰고, `RUNTIME_NO_KEYCHAIN`을 주면 키체인을 읽지 않음 |
| `--sprite-sheet <폴더>` | 모든 러너의 동작을 시트로 저장 |
| `--menubar-audit <폴더> [화면 배율] [메뉴바 높이] [크기 배율]` | 메뉴바 칸에서 잘림, 키, 어두운 윤곽을 `report.tsv`와 시트로 저장 |
| `--stage-shots <폴더> [러너 id] [트랙·날씨,...]` | 상태와 사용량 반응마다 무대 장면과 메뉴바 프레임을 PNG로 저장 |
| `--game-shots <폴더> [러너 id]` | 미니게임을 자동으로 플레이하며 장면을 PNG로 저장 (`RUNTIME_GAME_SCALE=2`면 게임 화면처럼 키워 찍음) |
| `--game-frames <폴더>` | README 게임 GIF용 장면을 이어 찍기 (`scripts/make-game-gif.sh`가 GIF로 만듦) |
| `--game-bench` | 무대와 게임 한 장면을 그리는 데 드는 시간 재기 (`BENCH_FRAMES`로 장면 수) |
| `--hero-gif <파일>` | README 맨 위 GIF 만들기 |
| `--redmine-check dupes` | 보낼 목록을 레드마인 댓글 꼴로 찍고, 일감마다 비슷한 댓글이 이미 있는지 읽어 봄 (쓰지 않음) |
| `--redmine-check screens <일감 번호>` | 그 일감 줄이 온 MR의 수정 전·후 화면을 GitLab에서 받아 레드마인에 올려만 보고, 보낼 댓글과 바꿀 상태를 찍음 (일감은 고치지 않음) |
| `--redmine-check <일감 번호>` | 앱의 보내기·되돌리기 코드로 시험 댓글을 한 일감에 보내고 줄바꿈이 살았는지 본 뒤 되돌림 (진척률·상태·날짜는 그대로). `RUNTIME_REDMINE_URL`·`RUNTIME_REDMINE_KEY`·`RUNTIME_WORKLOG`로 실행 |
| `--account-check [switch <이메일> \| simulate-limit \| refresh]` | 기억한 Claude 계정마다 저장본, 토큰 주인, 공식 사용률을 찍음. `refresh`는 쓰지 않는 계정 토큰이 곧 만료되면 먼저 새로 받아 저장함. `switch`는 그 계정으로 바꾸고, `simulate-limit`은 지금 계정이 한도에 막힌 것처럼 넣어 자동 전환을 확인 (설치한 앱 바이너리로 실행) |
| `--design-check <피그마 주소>` | 설정에 저장한 피그마 토큰으로 화면설계서 하나(주소에 `node-id`가 있으면 그 화면만)를 앱 코드 그대로 받아 보고, 읽은 화면·명세·이력 개수와 요청 수, 비교 이미지 하나를 받아 본 결과만 찍음 (기록은 저장하지 않음) |
| `--design-compare <파일 키> <기준 날짜> <비교 날짜> [화면 경로 \| screen:화면 ID]` | 날짜 비교를 앱 코드 그대로 두 번 돌려 버전, 변경 종류별 개수, 걸린 시간만 찍음 (두 번째는 저장해 둔 버전을 써서 바로 끝나야 함). 날짜는 `2026-10-25` 꼴 |
| `--diagnose` | 이 Mac의 빌드, macOS, 화면 구성, 업데이트 상태, 최근 문제 기록(`~/Library/Logs/RunTime/events.log`)을 찍음 |
| `--ui-shots <폴더>` | 팝오버, 앱 창 화면, 업무 일지를 실제 데이터로 찍어 PNG로 저장 (`RUNTIME_SHOTS=main-,worklog-day`처럼 이름 앞부분으로 고를 수 있음) |
| `--readme-shots <폴더>` | README 그림을 예시 값으로 찍기 (내 사용량과 지갑은 쓰지 않음) |
| `--game-sim [판 수] [목표 점수]` | 미니게임을 화면 없이 여러 판 돌려 초반 타이밍 창과 실력별 도달 점수 재기 |

진단 로그는 `log stream --predicate 'subsystem == "dev.runtime.RunTime"' --level debug`로 봅니다.

순위 서버는 `server/leaderboard/`에 있습니다(Cloudflare Workers + D1).

```bash
cd server/leaderboard
npm test                 # 규칙 테스트
npm run dev              # 로컬 서버를 띄운 뒤, 다른 터미널에서
node test/e2e.mjs        # 통합 테스트
npx wrangler@4 login && ./deploy.sh
```

</details>

## 출처와 라이선스

- 메뉴바 러너는 [RunCat](https://kyome.io/runcat/)에서, 미니게임의 무지개 꼬리는 냥캣에서 아이디어를 얻었습니다. 러너 그림은 모두 직접 그렸습니다.
- 미니게임의 장애물 간격과 속도 규칙은 [Chromium T-Rex Runner](https://chromium.googlesource.com/chromium/src/+/main/components/neterror/resources/)(BSD 3-Clause)를 따랐습니다.
- 미니게임 그림과 효과음은 Kenney의 [Pixel Platformer](https://kenney.nl/assets/pixel-platformer), [Digital Audio](https://kenney.nl/assets/digital-audio), [Music Jingles](https://kenney.nl/assets/music-jingles), [Interface Sounds](https://kenney.nl/assets/interface-sounds)(CC0)입니다.
- 미니게임 글자는 [Galmuri](https://github.com/quiple/galmuri)(SIL OFL 1.1) 픽셀 글꼴입니다. 한글·영문·기호만 남겨 싣습니다.
- 집계 규칙은 [ccusage](https://ccusage.com/guide/blocks-reports)를 참고했습니다.
- 비용 계산 단가는 ccusage와 같은 [LiteLLM 가격 데이터](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json)(MIT)에서 가져옵니다.

MIT 라이선스입니다. Anthropic, Claude와 관계없는 비공식 도구입니다.
