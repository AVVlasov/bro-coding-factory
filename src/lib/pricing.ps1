# pricing.ps1 — перевод токенов в деньги.
#
# ЧЕСТНОСТЬ ЭТОГО СЛОЯ ВАЖНЕЕ ЕГО ТОЧНОСТИ. Число, у которого не видно происхождения,
# принимают за факт, поэтому здесь у каждой цифры есть источник и оговорка:
#
#   · тарифы берутся из config/pricing.json проекта или memory/pricing.json фабрики.
#     Их никто не обновляет автоматически: прайсы меняются, а файл — нет. Поэтому вместе
#     с суммой всегда печатается ДАТА тарифов;
#   · у бэкендов без расхода токенов в потоке (cursor, gemini, aider) узлы приходят
#     нулевыми. Их стоимость НЕ додумывается: она помечается как неизвестная. Оценка «по
#     длине ответа» с погрешностью 15% в отчёте о деньгах — способ соврать уверенно;
#   · подписка и оплата по API — разные числа, и оба показываются. Одно из них всегда
#     выгоднее, и знать какое — единственная причина вообще считать деньги.

function Get-BcfPricing {
    param([Parameter(Mandatory)][string]$Project)

    foreach ($p in @((Join-Path $Project 'config\pricing.json'), (Join-Path (Get-BcfHome) 'memory\pricing.json'))) {
        if (Test-Path $p) {
            try {
                $j = Get-Content -Raw -LiteralPath $p | ConvertFrom-Json
                return [pscustomobject]@{ Source = $p; Updated = [string]$j.updated
                                          Currency = $(if ($j.currency) { [string]$j.currency } else { 'USD' })
                                          Rate = $(if ($j.rate) { [double]$j.rate } else { 1.0 })
                                          Models = $j.models; Plans = $j.plans }
            } catch { }
        }
    }
    return $null
}

# Цена узла. Возвращает $null, если посчитать честно нельзя — вызывающий обязан показать
# это как «неизвестно», а не как ноль. Ноль в колонке денег читается как «бесплатно».
function Get-BcfNodeCost {
    # Тарифов может не быть вовсе — это нормальное состояние, а не ошибка вызова:
    # проект вправе смотреть только токены.
    param($Pricing = $null, [string]$Model = '', [double]$Tokens = 0)

    if (-not $Pricing -or -not $Pricing.Models -or -not $Model -or $Tokens -le 0) { return $null }
    $m = $Pricing.Models.PSObject.Properties[$Model]
    if (-not $m) {
        # Ищем по вхождению: в конфиге модель часто записана с провайдером
        # (provider/Model-Name), а в журнале — как её вернул бэкенд. Из нескольких
        # совпавших ключей берём САМЫЙ ДЛИННЫЙ: «gpt-4o-mini» содержит и «gpt-4o»,
        # и первый по порядку мог бы посчитать mini по тарифу старшей модели —
        # разница в разы, молча.
        $m = $Pricing.Models.PSObject.Properties |
             Where-Object { $Model -like "*$($_.Name)*" } |
             Sort-Object { $_.Name.Length } -Descending |
             Select-Object -First 1
    }
    if (-not $m) { return $null }

    # В журнале лежит суммарный расход узла без разделения на вход и выход: бэкенды
    # отдают его по-разному, и приводить это к общему виду — отдельная работа. Пока её
    # нет, считаем по смешанной ставке и говорим об этом вслух.
    $blended = [double]$m.Value.blended
    if (-not $blended) {
        $in = [double]$m.Value.input; $out = [double]$m.Value.output
        if ($in -or $out) { $blended = ($in * 0.75 + $out * 0.25) } else { return $null }
    }
    return [double]($Tokens / 1000000.0 * $blended * $Pricing.Rate)
}

function Format-BcfMoney {
    param($Value, [string]$Currency = 'USD')
    if ($null -eq $Value) { return '—' }
    $sym = switch ($Currency) { 'RUB' { '₽' } 'EUR' { '€' } default { '$' } }
    return ('{0:N2} {1}' -f $Value, $sym)
}
