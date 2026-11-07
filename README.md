# RunTime

<p align="center">
  <img src="assets/runtime-run.gif" width="252" alt="메뉴바에서 달리는 RunTime 러너들">
</p>

Claude Code를 쓰는 만큼 macOS 메뉴바의 러너가 빨리 달립니다.
러너를 누르면 5시간 세션과 주간 사용률이 나와서, `/usage`를 치지 않아도 한도가 얼마나 남았는지 알 수 있습니다.

<p align="center">
  <img src="assets/readme-usage.png" width="260" alt="사용량 창: 무대에서 달리는 러너, 세션 42%, 주간 18%, 최근 30분 그래프">
  <img src="assets/readme-decor.png" width="260" alt="러너 화면: 펫, 배경, 효과, 게임 탭">
</p>

- 사용률은 Claude가 알려 주는 공식 값이라 웹과 데스크톱 앱에서 쓴 양도 들어갑니다.
- 80%, 95%에 닿으면 러너가 지치고 알림이 옵니다.
- 기본 펫 5종, 내 그림, [Petdex](https://petdex.dev) 펫 5천여 종 가운데 골라 달리고(이름은 한국어로 보입니다), 설명을 쓰고 `펫 만들기`를 누르면 이 Mac에서 FLUX.2 klein 4B로 Petdex와 같은 규격(동작 9줄)의 펫을 새로 그려 바로 러너로 고릅니다(6~8분, 무료). 원작이 있는 캐릭터는 그림을 넣지 않으면 Claude가 웹에서 그림을 찾아 맞는지 확인한 뒤 따라 그리고, 직접 넣은 그림(세 장까지)이 있으면 그 모습대로 그립니다. 다 만든 펫은 '고칠 점'을 적어 고칠 수 있고, `Petdex에 올리기`로 공식 CLI(`npx petdex`)를 통해 바로 올려 다른 사람도 받게 할 수 있습니다. `Petdex에서 찾기`로 직접 고를 수도 있고, 펫 폴더에 새로 생긴 펫은 저절로 등록합니다, 펫마다 Petdex 그림의 동작(손 흔들기, 점프, 생각, 지침)으로 상태를 보입니다.
- 무대에서 장애물 피하기 미니게임을 하고, 도트 배경 59종이 든 트랙과 꼬리·발먼지·부딪힘 같은 도트 효과를 조건 없이 골라 씁니다.
- 게임은 두 가지입니다. 달리기는 끝없이 달려 최고 점수에 도전하고, 비행은 누르는 동안 올라가며 끝없이 납니다. 멀리 갈수록 빨라지고 장애물 11가지 조각이 무작위로 나오며, 난이도를 쉬움, 보통, 어려움에서 고릅니다.
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
| 날짜별 사용량, 러너와 게임, 설정 | 러너를 오른쪽 클릭, 또는 사용량 창 아래 "앱 창에서 열기" |
| 업무 일지, 일일보고·주간 보고·레드마인 댓글 복사 | 러너를 오른쪽 클릭하고 "업무 일지" |
| 레드마인 일감 보기·고치기·댓글 | 앱 창 왼쪽 "레드마인"(⌘4). 내 일감, 프로젝트 전체, 저장한 질의를 표로 보고 일감을 눌러 그 자리에서 고침 |
| 피그마 화면설계서에서 바뀐 화면 보기 | 앱 창 왼쪽 "디자인"(⌘5), 또는 러너를 오른쪽 클릭하고 "디자인 변경" |
| 마크업할 화면 하나만 가져오기 | 피그마에서 화면을 "링크 복사"하고 디자인 화면의 🔗(⇧⌘V) |
| 마크업할 메뉴만 가져오기 | 디자인 화면에서 메뉴에 마우스를 올려 ↓, 또는 메뉴를 고르고 ⌘R |
| /etc/hosts 켜고 끄기, 정리, 백업 | 앱 창 왼쪽 "호스트"(⌘6), 또는 러너를 오른쪽 클릭하고 "호스트"에서 묶음을 바로 켜고 끄기. 저장할 때 관리자 암호를 묻습니다 |
| 호스트가 실제로 닿는지 보기 | 호스트 화면의 "접속 확인". 이름마다 주소 풀이, 포트, 웹 응답, 인증서를 한 번에 보고, 사내 주소가 모두 막혔으면 VPN을 먼저 보라고 알려 줌 |
| Claude 계정 바꾸기 | 러너를 오른쪽 클릭하고 "Claude 계정". 다른 계정은 Claude Code에서 `/login` 하면 저절로 추가되고, 설정 > 사용량에서 한도에 막히면 바로 다른 계정으로 바꾸게 할 수 있습니다 |
| 펫 바꾸기·동료 정하기 | 사용량 창에서 러너 이름(`고양이 ›`)을 누르고 펫 탭. 오른쪽 클릭으로 동료로 데려가기 |
| 미니게임 | 무대 오른쪽 위 "게임". 스페이스·클릭으로 점프(길게 누르면 높이), ↓로 숙이기 |
| 배경·효과·능력 고르기 | 러너 이름을 누르고 배경·효과·게임 탭 |

러너는 최근 1분 동안 쓴 토큰 양에 맞춰 걷고, 달리고, 질주합니다. 5분 넘게 쓰지 않으면 잡니다.

<p align="center">
  <img src="assets/runtime-game.gif" width="344" alt="미니게임: 고스트와 겨루며 무지개 꼬리를 단 고양이가 장애물을 넘는다">
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
설정, 최고 점수, 내 러너와 받은 펫, 로그인 시 자동 시작은 새 앱이 처음 켜질 때 옮겨 옵니다.
알림 허용은 한 번 더 묻습니다. 옛 설정(`dev.tokencat.TokenCat`)은 지우지 않으니 필요 없으면
`defaults delete dev.tokencat.TokenCat`로 지우세요.

## 무엇을 어디로 보내나

| 보내는 곳 | 언제 | 보내는 것 |
| --- | --- | --- |
| Anthropic | 3분마다 | Claude Code 로그인 토큰으로 사용률 조회 |
| Anthropic | Claude 계정이 둘 이상일 때 10분마다, 토큰이 바뀌었을 때 | 저장해 둔 다른 계정 토큰으로 사용률 조회, 토큰이 어느 계정 것인지 확인, 다른 계정 토큰이 만료되기 전에 리프레시 토큰으로 새로 받기 |
| Anthropic (내 Claude Code) | 업무 일지에서 "Claude로 다듬기"를 눌렀을 때, `--worklog polish` | 그날 진행 사항 글. 이 Mac의 `claude -p`를 내 로그인으로 부르고, 결과는 고쳐 쓸 수 있는 초안으로만 둠 |
| 보고 서버 | 업데이트 설치가 실패하거나 25분 넘게 멈췄을 때, 업데이트할지 가르지 못했을 때, 화면에서 일이 실패했을 때(레드마인·피그마 응답 오류, 일지·호스트·디자인 기록 파일을 읽거나 쓰지 못함, 팀즈 자동 보내기 실패, 사용량 창 잘림, 까닭을 가르지 못한 GitLab MR 받기 실패, 하루 넘게 이어진 업데이트 확인 실패. 토큰·권한·망 끊김은 빼고), 앱이 죽은 뒤 다시 켰을 때, 앱이 5초 넘게 멈췄을 때 (설정 > 일반 > 문제 기록에서 끔) | 무작위 설치 ID, 앱·macOS 버전과 커밋, 화면과 까닭, 실패한 코드 위치, 요청 길·보낸 칸·응답(일지 내용은 글자 수만), 사용자 폴더·이름·주소의 계정과 토큰을 가린 최근 기록. 앱이 죽었으면 macOS 충돌 보고서의 예외 종류와 호출 순서, 앱이 죽기 전에 찍은 오류 문구, 죽기 전까지의 기록. 앱이 멈췄으면 멈춘 시간, 그때 메인 스레드의 호출 순서, 앱 메모리·켠 뒤 시간·앱 창 화면 이름, 시스템 메모리 압박·스왑·CPU 부하·발열. 서버가 만든 사람에게 메일로 알리고(같은 까닭은 하루 한 통, 전체 하루 30통까지) 30일 뒤 지움 |
| huggingface.co | 펫 만들기를 처음 할 때 한 번 | 없음 (그림 모델 약 4.3GB를 받음. 그림 도구는 pypi.org에서 약 1GB) |
| petdex.dev | Petdex에서 받기를 열었을 때 | 없음 (펫 목록과 그림만 받음. 점프·생각 동작이 없는 예전 펫은 이때 그림을 한 번 다시 받음) |
| GitHub | 30분마다, 매일 오전 9시 | 없음 (공개 저장소의 커밋 비교만 받음) |
| Figma | 디자인 변경 기록에 화면설계서를 더했을 때, 프로젝트의 가져오기를 눌렀을 때, 주기를 정한 프로젝트는 그 주기마다, 상세에서 화면을 볼 때, 날짜 비교에서 버전 비교를 눌렀을 때 | 없음 (내 토큰으로 파일 정보, 버전 기록, 그 버전의 화면 노드, 프레임 이미지만 받음). 받은 내용은 이 Mac에만 저장 |

펫 그림은 이 Mac에서 그리고 설명과 참고 그림은 밖으로 보내지 않습니다. 다만 생김새와 이름을 정리하고, 원작 그림을 웹에서 찾아 확인하고, 옆모습 후보를 고를 때 이 Mac의 Claude Code를 씁니다. Petdex 목록을 열면 공식 이름표에 없는 펫 이름을 Claude(Haiku)로 한국어로 다듬어 저장해 둡니다. 받은 모델과 그림 도구(약 5GB)는 `~/Library/Application Support/RunTime/PetMaker`에 두고, 펫 탭 맨 아래에서 지울 수 있습니다. `~/.codex/pets`, `~/.petdex/pets`, `~/.runtime/pets`에서는 `pet.json`과 스프라이트 시트만 읽습니다.

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
<summary>점검용 실행 옵션과 보고 서버</summary>

`.build/debug/RunTime` 뒤에 붙여 실행합니다.

| 옵션 | 하는 일 |
| --- | --- |
| `--report` | 집계를 ccusage와 비교 |
| `--worklog <명령>` | 업무 일지를 보고서 글로 받거나 줄을 넣기 (`--worklog`만 치면 명령 목록). `RUNTIME_WORKLOG`로 다른 파일을 쓰고, `RUNTIME_NO_KEYCHAIN`을 주면 키체인을 읽지 않음 |
| `--sprite-sheet <폴더>` | 모든 러너의 동작을 시트로 저장 |
| `--stage-check` | 진짜 키 이벤트로 비행·달리기를 조작하며 시작, 끝남, 다시 시작, 나가기, 삼단 점프 높이 점검 |
| `--flight-shots <폴더>` | 비행 조각 화면 저장 |
| `--pet-make <설명>`, `--pet-watch [초]` | Claude로 펫 만들기와 펫 폴더 지켜보기를 실제로 돌려 상태 출력 |
| `--pet-import [폴더 또는 zip]` | `~/.codex/pets`·`~/.petdex/pets`에서 찾은 펫을 적고, 경로를 주면 가져오기 |
| `--petdex-extract <시트.png> <폴더>` | Petdex 시트를 러너 프레임(서 있기·달리기·점프·생각 등)으로 잘라 저장 |
| `--menubar-audit <폴더> [화면 배율] [메뉴바 높이] [크기 배율]` | 메뉴바 칸에서 잘림, 키, 어두운 윤곽을 `report.tsv`와 시트로 저장 |
| `--stage-shots <폴더> [러너 id 또는 sheet:<자른 폴더>] [트랙,...]` | 상태와 사용량 반응마다 무대 장면과 메뉴바 프레임을 PNG로 저장 |
| `--game-shots <폴더> [러너 id]` | 미니게임을 자동으로 플레이하며 장면을 PNG로 저장 (`RUNTIME_GAME_SCALE=2`면 게임 화면처럼 키워 찍음) |
| `--game-frames <폴더>` | README 게임 GIF용 장면을 이어 찍기 (`scripts/make-game-gif.sh`가 GIF로 만듦) |
| `--game-bench` | 무대와 게임 한 장면을 그리는 데 드는 시간 재기 (`BENCH_FRAMES`로 장면 수) |
| `--hero-gif <파일>` | README 맨 위 GIF 만들기 |
| `RUNTIME_MENU_CHECK=<폴더> RUNTIME_OPEN_PAGE=usage` | 앱 창의 메뉴를 차례로 열어 찍고 전환 시간과 메모리, 화면마다 스크롤을 내릴 때 걸리는 시간을 잼 (`RUNTIME_SCROLL_CHECK`를 주면 일지 주간·월간 스크롤까지 재고 끝냄). `RUNTIME_WORKLOG`, `RUNTIME_DESIGN_HISTORY`, `RUNTIME_HOSTS`로 사본을 가리키고 씀 |
| `--worklog-flow` | 일지를 레드마인으로 보내는 길을 가짜 응답으로 돌려, 실패 때 줄이 남는지와 겹쳐 나가지 않는지 살핌 (서버에 보내지 않음) |
| `--redmine-flow` | 레드마인 화면의 받기, 고치기, 댓글, 첨부, 관계, 새 일감, 찾기를 가짜 응답으로 끝까지 돌려 나가는 요청을 살핌 (서버에 보내지 않음) |
| `--redmine-check dupes` | 보낼 목록을 레드마인 댓글 꼴로 찍고, 일감마다 비슷한 댓글이 이미 있는지 읽어 봄 (쓰지 않음) |
| `--redmine-check screens <일감 번호>` | 그 일감 줄이 온 MR의 수정 전·후 화면을 GitLab에서 받아 레드마인에 올려만 보고, 보낼 댓글과 바꿀 상태를 찍음 (일감은 고치지 않음) |
| `--redmine-check share <일감 번호>` | 그 일감 줄이 온 MR의 화면을 GitLab에서 받아, 같은 MR을 나눠 받는 일감마다 어느 화면이 가는지와 그 근거만 찍음 (레드마인에 올리지 않음) |
| `--redmine-check <일감 번호>` | 앱의 보내기·되돌리기 코드로 시험 댓글을 한 일감에 보내고 줄바꿈이 살았는지 본 뒤 되돌림 (진척률·상태·날짜는 그대로). `RUNTIME_REDMINE_URL`·`RUNTIME_REDMINE_KEY`·`RUNTIME_WORKLOG`로 실행 |
| `--account-check [switch <이메일> \| simulate-limit \| refresh]` | 기억한 Claude 계정마다 저장본, 토큰 주인, 공식 사용률을 찍음. `refresh`는 쓰지 않는 계정 토큰이 곧 만료되면 먼저 새로 받아 저장함. `switch`는 그 계정으로 바꾸고, `simulate-limit`은 지금 계정이 한도에 막힌 것처럼 넣어 자동 전환을 확인 (설치한 앱 바이너리로 실행) |
| `--design-check <피그마 주소>` | 설정에 저장한 피그마 토큰으로 화면설계서 하나(주소에 `node-id`가 있으면 그 화면만)를 앱 코드 그대로 받아 보고, 읽은 화면·명세·이력 개수와 요청 수, 비교 이미지 하나를 받아 본 결과만 찍음 (기록은 저장하지 않음) |
| `--design-compare <파일 키> <기준 날짜> <비교 날짜> [화면 경로 \| screen:화면 ID]` | 날짜 비교를 앱 코드 그대로 두 번 돌려 버전, 변경 종류별 개수, 걸린 시간만 찍음 (두 번째는 저장해 둔 버전을 써서 바로 끝나야 함). 날짜는 `2026-10-25` 꼴 |
| `--update-check <커밋> <클론 경로> [owner/repo]` | 그 커밋으로 만든 빌드라 치고 GitHub와 견줘, 받을지(낡은 빌드·개발 빌드·판정 미룸) 판정만 찍음 (설치하지 않음) |
| `--report-preview [screen \| crash [파일.ips] \| hang]` | 만든 사람에게 보낼 때의 본문을 보내지 않고 찍음. `screen`은 화면 오류 본문, `crash`는 그 충돌 보고서(없으면 아직 알리지 않은 가장 최근 충돌)의 본문, `hang`은 메인 스레드를 1.5초 붙잡고 뜬 멈춤 본문 |
| `--design-qa <파일 키> <메뉴 경로> <폴더> [notoken \| hide \| verify]` | 디자인 화면을 기록 사본(`RUNTIME_DESIGN_HISTORY`)으로 띄워, 메뉴만 가져오기·대기열·반영·날짜 비교를 앱 함수 그대로 돌리고 피그마 요청 수·사본 파일·스냅숏으로 확인 (`RUNTIME_NO_KEYCHAIN`·`RUNTIME_FIGMA_TOKEN`으로 토큰) |
| `--hosts-check` | 켜진 호스트마다 주소 풀이, 443·80 포트, 웹 응답, 인증서를 앱 코드 그대로 보고 판정을 찍음 (`RUNTIME_HOSTS`로 다른 파일) |
| `--diagnose` | 이 Mac의 빌드, macOS, 화면 구성, 업데이트 상태, 최근 문제 기록(`~/Library/Logs/RunTime/events.log`)을 찍음 |
| `--ui-shots <폴더>` | 팝오버, 앱 창 화면, 업무 일지를 실제 데이터로 찍어 PNG로 저장 (`RUNTIME_SHOTS=main-,worklog-day`처럼 이름 앞부분으로 고를 수 있음) |
| `--readme-shots <폴더>` | README 그림을 예시 값으로 찍기 (내 사용량은 쓰지 않음) |
| `--game-sim [판 수] [목표 점수]` | 미니게임을 화면 없이 여러 판 돌려 초반 타이밍 창과 실력별 도달 점수 재기 |

진단 로그는 `log stream --predicate 'subsystem == "dev.runtime.RunTime"' --level debug`로 봅니다.

문제 보고를 받는 서버는 `server/leaderboard/`에 있습니다(Cloudflare Workers + D1).

```bash
cd server/leaderboard
npm test                 # 규칙 테스트
npm run dev              # 로컬 서버를 띄운 뒤, 다른 터미널에서
node test/e2e.mjs        # 통합 테스트
npx wrangler@4 login && ./deploy.sh
```

문제 보고 메일은 [Resend](https://resend.com)로 보냅니다. 받을 주소로 Resend에 가입해 API 키를 만든 뒤 Worker 비밀값으로 넣습니다(저장소에는 넣지 않음). 비밀값이 없으면 보고를 저장만 합니다.
메일에는 Claude Code에 그대로 붙여 넣을 글(그 빌드 코드 꺼내기·코드 줄 찾기 명령, 할 일, 상황, 같은 줄을 접은 기록)이 들어갑니다. 메일 프로그램은 스크립트를 막아, "복사하기" 단추는 보고마다 무작위 토큰을 붙인 복사 페이지(`/v1/reports/<열쇠>?t=<토큰>`)를 엽니다. 이 페이지도 보고와 함께 30일 뒤 사라집니다.

```bash
npx wrangler@4 secret put RESEND_API_KEY
npx wrangler@4 secret put REPORT_EMAIL     # 받을 주소 (Resend 가입 주소)
```

</details>

## 출처와 라이선스

- 메뉴바 러너는 [RunCat](https://kyome.io/runcat/)에서 아이디어를 얻었습니다.
- 기본 펫 5종은 pzUH(GameArt2D)의 CC0 그림입니다. 원본은 `Sources/RunTime/Assets/Pets/CREDITS.txt`에 있습니다.
- 도트 트랙 그림은 OpenGameArt의 CC0 그림을 무대 크기로 잘라 썼습니다. 작가와 원본은 `Sources/RunTime/Assets/Scenes/CREDITS.txt`에 있습니다.
- 미니게임의 장애물 간격과 속도 규칙은 [Chromium T-Rex Runner](https://chromium.googlesource.com/chromium/src/+/main/components/neterror/resources/)(BSD 3-Clause)를 따랐습니다.
- 꾸미기 효과, 말풍선, 코인 사탕, 새·슬라임, 비행 블록은 OpenGameArt의 CC0 그림입니다. 작가와 원본은 `Sources/RunTime/Assets/FX/CREDITS.txt`에 있습니다.
- 펫 만들기는 FLUX.2 klein 4B(Black Forest Labs, Apache 2.0)를 mflux(MIT)로 돌리고, 그림을 시트로 묶는 스크립트는 OpenAI hatch-pet(Apache 2.0)에서 가져왔습니다. `Sources/RunTime/Assets/PetMaker/CREDITS.txt`에 있습니다.
- 미니게임 그림과 효과음은 Kenney의 [Pixel Platformer](https://kenney.nl/assets/pixel-platformer), [Digital Audio](https://kenney.nl/assets/digital-audio), [Music Jingles](https://kenney.nl/assets/music-jingles), [Interface Sounds](https://kenney.nl/assets/interface-sounds)(CC0)입니다.
- 미니게임 글자는 [Galmuri](https://github.com/quiple/galmuri)(SIL OFL 1.1) 픽셀 글꼴입니다. 한글·영문·기호만 남겨 싣습니다.
- 집계 규칙은 [ccusage](https://ccusage.com/guide/blocks-reports)를 참고했습니다.
- 비용 계산 단가는 ccusage와 같은 [LiteLLM 가격 데이터](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json)(MIT)에서 가져옵니다.

MIT 라이선스입니다. Anthropic, Claude와 관계없는 비공식 도구입니다.
