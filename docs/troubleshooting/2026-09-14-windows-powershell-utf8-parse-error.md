# Windows PowerShell 5.1 UTF-8 스크립트 구문 오류 조사

- 상태: 해결
- 조사일: 2026-09-14
- 대상: `performance/k6/run-public-content-list-load.ps1`

## 증상

Windows PowerShell 5.1에서 실행기를 읽을 때 Markdown 표 문자열의 `|`, `%`, `ms`를 식으로 해석하며
`ExpressionsMustBeFirstInPipeline` 구문 오류가 발생했다. 같은 파일은 PowerShell 7 파서에서는 통과했다.

## 원인

스크립트에 한글 문자열이 추가됐지만 파일은 UTF-8 BOM 없이 저장됐다. Windows PowerShell 5.1이 파일을 시스템
ANSI 인코딩으로 해석하면서 한글 바이트 뒤의 ASCII 따옴표까지 잘못 소비했고, 이후 Markdown 행이 문자열이 아닌
PowerShell 식으로 파싱됐다. 기존 검증이 PowerShell 7 파서만 사용되어 이 호환 문제를 감지하지 못했다.

## 수정

한글 결과 문구와 실행 동작은 변경하지 않고 해당 `.ps1` 파일을 UTF-8 BOM으로 저장했다.

## 검증

- 수정 전 Windows PowerShell 5.1 파서에서 원래 구문 오류를 재현했다.
- 수정 후 Windows PowerShell 5.1.26100.9444 파서에서 오류 0건을 확인했다.
- PowerShell 7에서 수행한 기존 합성 결과 요약과 k6 threshold 계속 실행 검증은 유지된다.
