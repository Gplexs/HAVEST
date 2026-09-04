# HAVEST

Unity 프로젝트와 파일 기반 자율 개발 루프입니다. Windows 작업 스케줄러에
`HAVEST-AutonomousLoop`라는 이름으로 등록하며, 최초 등록 상태는 **비활성**입니다.

## 시작하기

프로젝트 폴더의 PowerShell에서 실행합니다. 먼저 `docs/DESIGN.md`,
`docs/STATUS.md`, `docs/feedback/INBOX.md`와 `loop/PROMPT.md`의 빈칸을 채우세요.

```powershell
# 켜기: STOP 해제 + 로그인 자동 시작 활성화 + 지금 시작
powershell -NoProfile -ExecutionPolicy Bypass -File .\loop\control.ps1 On

# 끄기: 로그인 자동 시작 비활성화 + 현재 바퀴 완료 후 종료
powershell -NoProfile -ExecutionPolicy Bypass -File .\loop\control.ps1 Off

# 상태 보기
powershell -NoProfile -ExecutionPolicy Bypass -File .\loop\control.ps1 Status
```

`Off`는 진행 중인 Codex 프로세스를 강제 종료하지 않습니다. `loop/STOP`을
만들고 자동 실행을 비활성화합니다. 직접 `loop/STOP`을 만들어도 현재 바퀴를
마친 뒤 정상 종료합니다. 대기 중이면 바로 멈춥니다. `On`은 STOP을 지웁니다.

다른 PC에 복제하거나 경로를 바꾼 경우 `loop/env.ps1`의 설치 경로를 맞추고
다시 등록합니다. `Register`는 항상 비활성 상태로 등록하며 시작하지 않습니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\loop\control.ps1 Register
```

## 한 바퀴의 동작

매번 별도의 `codex exec --ephemeral --json` 프로세스를 시작하고,
`loop/PROMPT.md`를 읽고 한 바퀴만 수행하라고 전달합니다. `resume`, `fork`,
이전 대화 ID 전달은 사용하지 않습니다. 다음 바퀴의 기억은 저장소 파일입니다.

INBOX를 먼저 읽고, DESIGN과 STATUS를 확인한 뒤 한 가지 작업을 합니다.
기계 검사를 통과한 변경을 먼저 커밋하고 화면을 확인합니다. 화면 확인으로
고친 사항은 다시 검사·커밋하고, 마지막 STATUS 갱신도 커밋합니다.
원격 push는 루프가 자동으로 수행하는 단계에 포함하지 않았습니다.

정상 모드는 `--approve-for-me`로 프로젝트 쓰기 샌드박스와 자동 승인 검토를
사용합니다. `.git`처럼 보호되는 경로의 커밋 명령은 자동 검토가 판단하므로
사람의 승인 입력을 기다리지 않습니다. 자동 검토에서 거절한 명령은 실행되지
않으며 그 결과는 바퀴 로그에 남습니다. 시험 모드는 `-a never --sandbox read-only`입니다.
Codex 로그인은 현재 Windows 사용자의 기존 인증을 사용합니다.
자격 증명은 저장소에 넣지 않습니다.

## 설정

요청한 `loop/env.sh`가 설정 원본입니다. Windows에서는 `loop/env.ps1`이
단순 대입문만 읽으므로 Bash 설치가 필요 없습니다.

| 설정 | 기본값 | 의미 |
| --- | --- | --- |
| `LOOP_MODEL` | `gpt-5.6-sol` | Codex 모델 |
| `LOOP_MAX_TURNS` | `1` | 한 바퀴에서 허용하는 Codex 사용자 턴의 상한 |
| `LOOP_WAIT_SECONDS` | `30` | 바퀴 사이 대기 시간(초) |
| `LOOP_MAX_ROUNDS` | `0` | 한 번 시작한 루프의 최대 바퀴 수, 0은 무한 |
| `LOOP_ROUND_TIMEOUT_SECONDS` | `3600` | 한 바퀴의 시간 제한(초) |

**턴 제한의 정확한 의미:** 설치된 Codex CLI에는 `--max-turns` 옵션이 없습니다.
이 루프는 JSON의 `turn.started`를 세어 상한을 검사합니다. 새 `codex exec`에
프롬프트 하나만 주므로 실제 한 바퀴는 사용자 턴 하나이며, 상한을 1보다 크게
설정해도 대화를 이어 보내지 않습니다. 턴 안의 도구 호출이나 내부 추론 횟수를
뜻하지 않습니다. 오래 끝나지 않는 작업은 시간 제한으로 종료합니다.

설정은 루프를 시작할 때 읽습니다. 변경 후 `Off`로 현재 바퀴의 종료를 기다린 뒤
`On`으로 다시 시작하면 적용됩니다. PROMPT와 기억 문서는 매 바퀴 새로 읽습니다.

`loop/env.ps1`에 Codex·샌드박스 보조 도구·ripgrep·Git·PowerShell·Node와
Windows 기본 도구의 절대 PATH를 명시했습니다. 현재 CLI는 보조 실행 파일이
함께 설치된 데스크톱 번들을 사용합니다. 자동 실행은 터미널의 PATH나 프로필에
의존하지 않습니다. Codex 업데이트로 해당 번들 경로가 사라지면 이 파일의
`$codexDir`와 `$ripgrepDir`를 갱신하세요.

## 자동 실행과 장애 처리

- 현재 Windows 사용자의 로그인 때 실행합니다. 작업은 해당 사용자 권한으로 동작합니다.
- 오류 종료는 1분 후 재시도하며 작업 스케줄러 재시도 상한은 999회입니다.
- STOP 및 최대 바퀴 수 도달은 종료 코드 0이며, 장애 재시작을 하지 않습니다.
- 최대 바퀴 수 도달 후에도 자동 실행이 활성 상태면 다음 로그인 때 새로 시작합니다.
- 시간 초과, Codex 오류, 잘못된 로그/설정은 비정상 종료로 기록합니다.
- 작업 스케줄러의 실행 시간 제한은 없으며, 중복 실행은 무시합니다.
- 수동 실행과 자동 실행 사이의 중복도 `logs/loop.lock`의 OS 파일 잠금으로 막습니다.

`Status`의 `Enabled=False`, `State=Disabled`는 자동 실행이 꺼져 있음을,
`LoopLockHeld=False`는 현재 루프가 실행 중이지 않음을 뜻합니다.
`LastResultMeaning=NeverRun`은 작업 스케줄러가 아직 실행한 적 없다는 뜻입니다.
수동 시험 결과는 `LastRecordedRun`과 로그에서 확인합니다.

## 두 바퀴 시험과 로그

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\loop\loop.ps1 -SmokeTest -MaxRounds 2 -WaitSeconds 1

# 최신 로그 파일 목록
Get-ChildItem .\logs -Recurse -File | Sort-Object LastWriteTime -Descending | Select-Object -First 12 FullName
```

`-SmokeTest`는 실제 Codex CLI를 두 번 새로 열어 네 문서의 읽기만 확인합니다.
시험 지시는 실행 시에만 전달하며, `PROMPT.md`에는 들어 있지 않습니다.
시험도 STOP을 존중하므로 STOP이 있으면 시작하지 않습니다.

2026-09-04 설치 검증에서 두 바퀴 모두 `SMOKE_OK`, 종료 코드 0을 확인했습니다.
두 프로세스의 PID와 세션 ID가 각각 달랐고, Unity 파일 변경은 없었습니다.
처음 발견한 샌드박스 보조 실행 파일 누락은 완전한 CLI 번들 경로를 지정해 해결했습니다.

| 바퀴 | PID | 새 세션 ID | 결과 |
| --- | --- | --- | --- |
| 1 | 28836 | `01a06b75-110e-7e60-8727-494bbceaa200` | `SMOKE_OK round=1`, exit 0 |
| 2 | 41296 | `01a06b75-b440-7dd0-b4f8-7c82a7d6b7b7` | `SMOKE_OK round=2`, exit 0 |

실제 시험 전체 로그: `logs/2026-09-04/20260904-170706-831-35796-smoke.log`.

로그는 `logs/YYYY-MM-DD/`에 남깁니다. 바퀴마다 시작·종료 시간, PID,
서로 다른 thread ID, 종료 코드, 사용량과 마지막 응답을 저장합니다.

| 로그 | 내용 |
| --- | --- |
| `*-smoke.log` / `*-development.log` | 실행 전체의 시작·종료와 바퀴 요약 |
| `*-round-NNNN.events.jsonl` | Codex JSON 이벤트 원본 |
| `*-round-NNNN.stderr.log` | CLI 진단 및 오류 |
| `*-round-NNNN.summary.json` | 바퀴 결과와 새 세션 ID |
| `*-round-NNNN.last-message.txt` | 최종 응답 |
| `logs/loop-state.json` | 제어 스크립트에서 읽는 최근 상태 |
| `logs/scheduler-YYYY-MM-DD.log` | 자동 실행 진입점의 시작 실패 |

Windows에서는 기존 Unity `Logs/`와 `logs/`가 같은 폴더입니다.
로그 내용과 STOP은 Git에서 제외합니다. `.gitkeep`만 추적합니다.

## 만든 파일

| 파일 | 역할 |
| --- | --- |
| `.gitignore` | Unity 캐시, 빌드, 로그, 로컬 상태와 인증 파일 제외 |
| `.gitattributes` | 텍스트 줄바꿈 설정 |
| `loop/loop.ps1` | 매 바퀴 새 세션, 로그, STOP, 제한, 중복 방지 |
| `loop/env.sh` | 모델·턴·대기·바퀴 수·시간 제한 설정 |
| `loop/env.ps1` | Windows 설정 로더와 명시적 PATH |
| `loop/control.ps1` | 등록·켜기·끄기·상태 |
| `loop/scheduled.ps1` | 작업 스케줄러 진입점 |
| `loop/PROMPT.md` | 여섯 절짜리 지시서 틀 |
| `docs/DESIGN.md` | 초기 기획서 빈 틀 |
| `docs/STATUS.md` | 매 바퀴 진행 상태 빈 틀 |
| `docs/feedback/INBOX.md` | 우선 처리 지시 빈 틀 |
| `Logs/.gitkeep` | 로그 폴더 유지 |
| `README.md` | 설치·운영·시험 안내 |

CLI 실행 방식과 이벤트 형식은 [OpenAI 공식 비대화형 모드 문서](https://learn.chatgpt.com/docs/non-interactive-mode)와
[CLI 명령 문서](https://learn.chatgpt.com/docs/developer-commands?surface=cli)를 기준으로 확인했습니다.
