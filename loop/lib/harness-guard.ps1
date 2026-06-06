# harness-guard.ps1 — защита harness-скриптов от прямого вызова агентом.
#
# Контекст инцидента: кодовый агент в opencode-сессии самостоятельно запустил
# `pwsh loop/lint-gate.ps1` (вероятно, чтобы посмотреть violations) → скрипт
# исполнялся внутри LLM-сессии → итерация убита по таймауту. Запуск opencode-агента
# идёт с --dangerously-skip-permissions, поэтому хуки pre-bash-guard не срабатывают —
# нужен в-скриптовой guard.
#
# Механика: loop.ps1 / verify.ps1 устанавливают $env:RALPH_HARNESS_TOKEN = "<random>"
# для дочерних процессов (включая opencode run). Этот токен агент **унаследует** —
# поэтому полагаться только на env нельзя. Дополнительно проверяем цепочку родительских
# процессов: если в ней есть `opencode` (имя процесса) И НЕТ `loop.ps1` / `verify.ps1`
# в командной строке pwsh-предка — значит вызов идёт из агентского sandboxed shell.
#
# Использование (в начале каждого harness-ps1):
#   . (Join-Path $PSScriptRoot 'lib\harness-guard.ps1')
#   Assert-HarnessCaller -ScriptName 'lint-gate.ps1'
#
# При нарушении: пишет понятное сообщение в stdout, эмитит event `agent-self-invoke`,
# и делает exit 0 (НЕ exit ≠0 — иначе агент решит «ошибка инструмента» и пойдёт чинить
# чужой код). Цель — мягко сказать «не твоё дело» и быстро вернуть управление.

$script:RalphGuardActive = $true

function _Get-ProcessChain {
    # Возвращает массив @{Id; Name; CmdLine} для PID-чейна от текущего до корня.
    $chain = @()
    $pid_cursor = $PID
    $hop = 0
    while ($pid_cursor -and $hop -lt 12) {
        $hop++
        try {
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$pid_cursor" -ErrorAction Stop
        } catch { break }
        if (-not $p) { break }
        $chain += [PSCustomObject]@{
            Id      = [int]$p.ProcessId
            Name    = [string]$p.Name
            CmdLine = [string]$p.CommandLine
        }
        if (-not $p.ParentProcessId -or $p.ParentProcessId -eq $p.ProcessId) { break }
        $pid_cursor = [int]$p.ParentProcessId
    }
    return $chain
}

function Assert-HarnessCaller {
    param(
        [Parameter(Mandatory)] [string] $ScriptName,
        [string[]] $AllowedParents = @('loop.ps1', 'verify.ps1', 'start.ps1', 'inspect.ps1')
    )
    if (-not $script:RalphGuardActive) { return }

    # 1) Override: явный токен от внешнего harness-launcher (для интеграционных тестов
    #    и ручного запуска оператором).
    if ($env:RALPH_GUARD_BYPASS -eq '1') { return }

    # 2) Композитная проверка:
    #    - parent IS loop.ps1/verify.ps1 → ALLOW (легитимный harness-flow).
    #    - parent НЕ harness, но opencode в цепочке предков → BLOCK (агент из opencode run).
    #    - parent НЕ harness и opencode НЕТ в предках → ALLOW (ручной запуск из терминала).
    #
    #    Почему immediate parent, а не «opencode где-то в цепочке»: в норме loop.ps1
    #    запускается через slash-команду → start.ps1 → loop.ps1, и opencode-desktop
    #    висит в предках. Старая проверка «opencode anywhere» давала ложное срабатывание.
    $chain = _Get-ProcessChain
    $immediateParent = $chain | Select-Object -Skip 1 -First 1   # [0]=self, [1]=parent

    $parentIsAllowedHarness = $false
    if ($immediateParent -and $immediateParent.CmdLine) {
        foreach ($allow in $AllowedParents) {
            if ($immediateParent.CmdLine -match [regex]::Escape($allow)) {
                $parentIsAllowedHarness = $true; break
            }
        }
    }
    if ($parentIsAllowedHarness) { return }

    $hasOpencodeAncestor = $false
    foreach ($p in ($chain | Select-Object -Skip 1)) {
        if ($p.Name -match '^opencode(\.exe)?$') { $hasOpencodeAncestor = $true; break }
    }
    if (-not $hasOpencodeAncestor) { return }   # ручной запуск оператором — пропуск

    if ($true) {   # достигли сюда → агентский self-invoke
        $callerHint = ($chain | Select-Object -First 6 | ForEach-Object {
            "  PID=$($_.Id) $($_.Name): $($_.CmdLine -replace "`r|`n", ' ' | Select-Object -First 1)"
        }) -join "`n"

        Write-Output @"
==============================================================================
HARNESS-GUARD: вызов $ScriptName из агентской opencode-сессии запрещён.
==============================================================================

Этот скрипт — часть harness. Его автоматически крутит loop/loop.ps1 между
итерациями; результаты приходят к тебе через loop/STATE.md (BACKPRESSURE-блок).

Самостоятельный запуск из агентской сессии = ровно тот баг, который убивает
итерацию — opencode run зависает по таймауту, потому что скрипт исполняется
внутри LLM-сессии.

Что делать вместо этого:
  - смотреть последний backpressure: loop/STATE.md (раздел BACKPRESSURE);
  - просить верификацию: создать файл loop/VERIFY-REQUEST (loop.ps1 сам
    вызовет verify.ps1 → judge);
  - смотреть последние события: loop/events.jsonl (только Read, не запускать
    inspect.ps1).

Process chain (первые 6 уровней):
$callerHint

Вызов проигнорирован. Возвращаю exit 0, чтобы не сбить твою итерацию ложной
ошибкой инструмента. Просто не запускай harness-скрипты — они не для тебя.
==============================================================================
"@

        # Эмитим event для трекинга в audit-log; токен новой сессии не нужен —
        # просто append-only запись.
        try {
            $busLib = Join-Path $PSScriptRoot 'event-bus.ps1'
            if (Test-Path $busLib) {
                . $busLib
                Initialize-EventBus -RalphRoot (Split-Path $PSScriptRoot -Parent)
                Append-Event -EventType 'agent-self-invoke' -Phase 'guard' `
                    -Payload @{
                        script = $ScriptName
                        chain  = @($chain | Select-Object -First 6 | ForEach-Object { "$($_.Name):$($_.Id)" })
                    }
            }
        } catch { }

        # exit 0 — намеренно. См. комментарий выше.
        exit 0
    }
}
