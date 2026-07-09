Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$Script:AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:DownloadDir = Join-Path $Script:AppDir "downloads"
$Script:LogDir = Join-Path $Script:AppDir "logs"
New-Item -ItemType Directory -Force -Path $Script:DownloadDir, $Script:LogDir | Out-Null

$Script:Jobs = New-Object System.Collections.ArrayList
$Script:Stopping = $false

function Get-YtDlpPath {
    $local = Join-Path $Script:AppDir "yt-dlp.exe"
    if (Test-Path $local) { return $local }

    $cmd = Get-Command "yt-dlp.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    return $null
}

function Quote-CmdArg([string]$Value) {
    if ($null -eq $Value) { return '""' }
    return '"' + ($Value -replace '"', '""') + '"'
}

function Quote-WindowsArg([string]$Value) {
    if ($null -eq $Value) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Resolve-CookiePath([string]$Cookies) {
    if ($Cookies.Trim().Length -eq 0) { return "" }
    $cookiePath = $Cookies.Trim()
    if (-not [System.IO.Path]::IsPathRooted($cookiePath)) {
        $cookiePath = Join-Path $Script:AppDir $cookiePath
    }
    return $cookiePath
}

function Get-LogSummary([string]$LogPath) {
    if (-not $LogPath -or -not (Test-Path $LogPath)) { return "沒有找到記錄檔" }

    $lines = @(Get-Content -Path $LogPath -Tail 18 -ErrorAction SilentlyContinue)
    $important = @($lines | Where-Object {
        $_ -match "ERROR|Error|failed|Failed|Unable|unsupported|HTTP Error|cookies|ffmpeg|proxy|timed out|certificate|Private video|Sign in"
    })

    if ($important.Count -gt 0) {
        return (($important | Select-Object -Last 3) -join " | ")
    }

    if ($lines.Count -gt 0) {
        return (($lines | Select-Object -Last 3) -join " | ")
    }

    return "記錄檔是空的"
}

function Update-JobProgress($Job) {
    if (-not $Job.LogPath -or -not (Test-Path $Job.LogPath)) { return $false }

    $lines = @(Get-Content -Path $Job.LogPath -Tail 80 -ErrorAction SilentlyContinue)
    $progressLines = @($lines | Where-Object { $_ -match "^\[download\]\s+\d+(\.\d+)?%" })
    if ($progressLines.Count -eq 0) { return $false }

    $line = $progressLines[-1]
    $changed = $false

    if ($line -match "^\[download\]\s+(?<percent>\d+(?:\.\d+)?)%") {
        $newProgress = [Math]::Min(100, [Math]::Max(0, [double]$Matches.percent))
        if ($Job.Progress -ne $newProgress) {
            $Job.Progress = $newProgress
            $changed = $true
        }
    }

    if ($line -match " at\s+(?<speed>.+?)\s+ETA\s+(?<eta>\S+)") {
        if ($Job.Speed -ne $Matches.speed.Trim()) {
            $Job.Speed = $Matches.speed.Trim()
            $changed = $true
        }
        if ($Job.Eta -ne $Matches.eta.Trim()) {
            $Job.Eta = $Matches.eta.Trim()
            $changed = $true
        }
    } elseif ($line -match " in\s+(?<time>\S+)\s+at\s+(?<speed>.+?)\s*$") {
        if ($Job.Progress -ne 100) {
            $Job.Progress = 100
            $changed = $true
        }
        if ($Job.Speed -ne $Matches.speed.Trim()) {
            $Job.Speed = $Matches.speed.Trim()
            $changed = $true
        }
        if ($Job.Eta -ne "完成") {
            $Job.Eta = "完成"
            $changed = $true
        }
    }

    if ($line -match "\(frag\s+(?<frag>\d+/\d+)\)") {
        if ($Job.Fragment -ne $Matches.frag) {
            $Job.Fragment = $Matches.frag
            $changed = $true
        }
    }

    return $changed
}

function New-DownloadArguments {
    param(
        [string]$Url,
        [string]$Proxy,
        [string]$Cookies,
        [string]$OutputDir,
        [int]$Fragments
    )

    $args = New-Object System.Collections.Generic.List[string]
    if ($Proxy.Trim().Length -gt 0) {
        $args.Add("--proxy")
        $args.Add($Proxy.Trim())
    }
    if ($Cookies.Trim().Length -gt 0) {
        $cookiePath = Resolve-CookiePath $Cookies
        $args.Add("--cookies")
        $args.Add($cookiePath)
    }
    $args.Add("-f")
    $args.Add("bv*+ba/b")
    $args.Add("--merge-output-format")
    $args.Add("mp4")
    $args.Add("--write-thumbnail")
    $args.Add("--embed-metadata")
    $args.Add("--newline")
    $args.Add("--no-mtime")
    $args.Add("--windows-filenames")
    $args.Add("--restrict-filenames")
    $args.Add("--retries")
    $args.Add("10")
    $args.Add("--fragment-retries")
    $args.Add("10")
    $args.Add("--concurrent-fragments")
    $args.Add([Math]::Max(1, $Fragments).ToString())
    $args.Add("-P")
    $args.Add($OutputDir)
    $args.Add("-o")
    $args.Add("%(title).80s-%(id)s.%(ext)s")
    $args.Add($Url)

    $quoted = @()
    foreach ($arg in $args) { $quoted += (Quote-WindowsArg $arg) }
    return ($quoted -join " ")
}

function Get-ReadableLogPath($Job) {
    if ($Job.ErrPath -and (Test-Path $Job.ErrPath) -and ((Get-Item $Job.ErrPath).Length -gt 0)) {
        return $Job.ErrPath
    }
    return $Job.LogPath
}

function Update-Buttons {
    $runningCount = ($Script:Jobs | Where-Object { $_.Status -eq "下載中" }).Count
    $pendingCount = ($Script:Jobs | Where-Object { $_.Status -eq "等待中" }).Count
    $btnStart.Enabled = ($runningCount -eq 0 -and $pendingCount -eq 0)
    $btnStop.Enabled = ($runningCount -gt 0 -or $pendingCount -gt 0)
}

function Refresh-List {
    $list.Items.Clear()
    foreach ($job in $Script:Jobs) {
        $item = New-Object System.Windows.Forms.ListViewItem($job.Status)
        [void]$item.SubItems.Add($job.Url)
        [void]$item.SubItems.Add(("{0:N1}%" -f [double]$job.Progress))
        [void]$item.SubItems.Add($job.Speed)
        [void]$item.SubItems.Add($job.Eta)
        [void]$item.SubItems.Add($job.Fragment)
        [void]$item.SubItems.Add($job.Error)
        [void]$item.SubItems.Add($job.LogPath)
        $item.Tag = $job
        [void]$list.Items.Add($item)
    }
    Update-Buttons
}

function Start-NextDownloads {
    if ($Script:Stopping) { return }

    $yt = Get-YtDlpPath
    if (-not $yt) {
        $status.Text = "找不到 yt-dlp.exe"
        return
    }

    $max = [int]$numParallel.Value
    $running = ($Script:Jobs | Where-Object { $_.Status -eq "下載中" }).Count
    $slots = $max - $running
    if ($slots -le 0) { return }

    $pending = @($Script:Jobs | Where-Object { $_.Status -eq "等待中" } | Select-Object -First $slots)
    foreach ($job in $pending) {
        $job.Status = "下載中"
        $logName = "{0:yyyyMMdd-HHmmss}-{1}.log" -f (Get-Date), ([Guid]::NewGuid().ToString("N").Substring(0, 8))
        $job.LogPath = Join-Path $Script:LogDir $logName
        $job.ErrPath = Join-Path $Script:LogDir ($logName -replace "\.log$", ".error.log")

        $arguments = New-DownloadArguments `
            -Url $job.Url `
            -Proxy $txtProxy.Text `
            -Cookies $txtCookies.Text `
            -OutputDir $txtOutput.Text `
            -Fragments ([int]$numFragments.Value)

        $job.Process = Start-Process `
            -FilePath $yt `
            -ArgumentList $arguments `
            -WorkingDirectory $Script:AppDir `
            -RedirectStandardOutput $job.LogPath `
            -RedirectStandardError $job.ErrPath `
            -WindowStyle Hidden `
            -PassThru
    }
    Refresh-List
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Smart Video Downloader"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(900, 720)
$form.MinimumSize = New-Object System.Drawing.Size(820, 660)
$form.Font = New-Object System.Drawing.Font("Microsoft JhengHei UI", 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = "Smart Video Downloader"
$title.Font = New-Object System.Drawing.Font("Microsoft JhengHei UI", 16, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(18, 16)
$form.Controls.Add($title)

$lblUrls = New-Object System.Windows.Forms.Label
$lblUrls.Text = "影片網址（一行一條）"
$lblUrls.AutoSize = $true
$lblUrls.Location = New-Object System.Drawing.Point(20, 60)
$form.Controls.Add($lblUrls)

$txtUrls = New-Object System.Windows.Forms.TextBox
$txtUrls.Multiline = $true
$txtUrls.ScrollBars = "Vertical"
$txtUrls.Location = New-Object System.Drawing.Point(20, 84)
$txtUrls.Size = New-Object System.Drawing.Size(840, 130)
$txtUrls.Anchor = "Top,Left,Right"
$form.Controls.Add($txtUrls)

$lblProxy = New-Object System.Windows.Forms.Label
$lblProxy.Text = "代理"
$lblProxy.AutoSize = $true
$lblProxy.Location = New-Object System.Drawing.Point(20, 232)
$form.Controls.Add($lblProxy)

$txtProxy = New-Object System.Windows.Forms.TextBox
$txtProxy.Text = "socks5://127.0.0.1:7898"
$txtProxy.Location = New-Object System.Drawing.Point(82, 228)
$txtProxy.Size = New-Object System.Drawing.Size(260, 25)
$form.Controls.Add($txtProxy)

$lblCookies = New-Object System.Windows.Forms.Label
$lblCookies.Text = "Cookies"
$lblCookies.AutoSize = $true
$lblCookies.Location = New-Object System.Drawing.Point(370, 232)
$form.Controls.Add($lblCookies)

$txtCookies = New-Object System.Windows.Forms.TextBox
$txtCookies.Text = "cookies.txt"
$txtCookies.Location = New-Object System.Drawing.Point(438, 228)
$txtCookies.Size = New-Object System.Drawing.Size(180, 25)
$form.Controls.Add($txtCookies)

$lblParallel = New-Object System.Windows.Forms.Label
$lblParallel.Text = "同時下載"
$lblParallel.AutoSize = $true
$lblParallel.Location = New-Object System.Drawing.Point(20, 272)
$form.Controls.Add($lblParallel)

$numParallel = New-Object System.Windows.Forms.NumericUpDown
$numParallel.Minimum = 1
$numParallel.Maximum = 8
$numParallel.Value = 3
$numParallel.Location = New-Object System.Drawing.Point(82, 268)
$numParallel.Size = New-Object System.Drawing.Size(70, 25)
$form.Controls.Add($numParallel)

$lblFragments = New-Object System.Windows.Forms.Label
$lblFragments.Text = "分段併發"
$lblFragments.AutoSize = $true
$lblFragments.Location = New-Object System.Drawing.Point(180, 272)
$form.Controls.Add($lblFragments)

$numFragments = New-Object System.Windows.Forms.NumericUpDown
$numFragments.Minimum = 1
$numFragments.Maximum = 16
$numFragments.Value = 8
$numFragments.Location = New-Object System.Drawing.Point(248, 268)
$numFragments.Size = New-Object System.Drawing.Size(70, 25)
$form.Controls.Add($numFragments)

$lblOutput = New-Object System.Windows.Forms.Label
$lblOutput.Text = "儲存位置"
$lblOutput.AutoSize = $true
$lblOutput.Location = New-Object System.Drawing.Point(348, 272)
$form.Controls.Add($lblOutput)

$txtOutput = New-Object System.Windows.Forms.TextBox
$txtOutput.Text = $Script:DownloadDir
$txtOutput.Location = New-Object System.Drawing.Point(422, 268)
$txtOutput.Size = New-Object System.Drawing.Size(340, 25)
$txtOutput.Anchor = "Top,Left,Right"
$form.Controls.Add($txtOutput)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "選擇"
$btnBrowse.Location = New-Object System.Drawing.Point(774, 266)
$btnBrowse.Size = New-Object System.Drawing.Size(86, 30)
$btnBrowse.Anchor = "Top,Right"
$form.Controls.Add($btnBrowse)

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = "開始下載"
$btnStart.Location = New-Object System.Drawing.Point(20, 315)
$btnStart.Size = New-Object System.Drawing.Size(120, 36)
$form.Controls.Add($btnStart)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = "停止全部"
$btnStop.Location = New-Object System.Drawing.Point(150, 315)
$btnStop.Size = New-Object System.Drawing.Size(120, 36)
$btnStop.Enabled = $false
$form.Controls.Add($btnStop)

$btnOpen = New-Object System.Windows.Forms.Button
$btnOpen.Text = "開啟下載資料夾"
$btnOpen.Location = New-Object System.Drawing.Point(280, 315)
$btnOpen.Size = New-Object System.Drawing.Size(140, 36)
$form.Controls.Add($btnOpen)

$btnLog = New-Object System.Windows.Forms.Button
$btnLog.Text = "開啟記錄"
$btnLog.Location = New-Object System.Drawing.Point(430, 315)
$btnLog.Size = New-Object System.Drawing.Size(120, 36)
$form.Controls.Add($btnLog)

$list = New-Object System.Windows.Forms.ListView
$list.View = "Details"
$list.FullRowSelect = $true
$list.GridLines = $true
$list.Location = New-Object System.Drawing.Point(20, 370)
$list.Size = New-Object System.Drawing.Size(840, 235)
$list.Anchor = "Top,Bottom,Left,Right"
[void]$list.Columns.Add("狀態", 90)
[void]$list.Columns.Add("網址", 250)
[void]$list.Columns.Add("進度", 80)
[void]$list.Columns.Add("速度", 100)
[void]$list.Columns.Add("ETA", 70)
[void]$list.Columns.Add("分段", 70)
[void]$list.Columns.Add("錯誤摘要", 190)
[void]$list.Columns.Add("記錄檔", 140)
$form.Controls.Add($list)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Minimum = 0
$progress.Maximum = 1000
$progress.Value = 0
$progress.Location = New-Object System.Drawing.Point(20, 615)
$progress.Size = New-Object System.Drawing.Size(840, 16)
$progress.Anchor = "Bottom,Left,Right"
$form.Controls.Add($progress)

$status = New-Object System.Windows.Forms.Label
$status.Text = "準備就緒"
$status.AutoSize = $false
$status.Location = New-Object System.Drawing.Point(20, 635)
$status.Size = New-Object System.Drawing.Size(840, 24)
$status.Anchor = "Bottom,Left,Right"
$form.Controls.Add($status)

$btnBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.SelectedPath = $txtOutput.Text
    if ($dialog.ShowDialog() -eq "OK") {
        $txtOutput.Text = $dialog.SelectedPath
    }
})

$btnOpen.Add_Click({
    New-Item -ItemType Directory -Force -Path $txtOutput.Text | Out-Null
    Start-Process explorer.exe -ArgumentList (Quote-CmdArg $txtOutput.Text)
})

$btnLog.Add_Click({
    if ($list.SelectedItems.Count -eq 0) { return }
    $job = $list.SelectedItems[0].Tag
    $path = Get-ReadableLogPath $job
    if ($path -and (Test-Path $path)) {
        Start-Process notepad.exe -ArgumentList (Quote-CmdArg $path)
    }
})

$list.Add_DoubleClick({
    if ($list.SelectedItems.Count -eq 0) { return }
    $job = $list.SelectedItems[0].Tag
    $path = Get-ReadableLogPath $job
    if ($path -and (Test-Path $path)) {
        Start-Process notepad.exe -ArgumentList (Quote-CmdArg $path)
    }
})

$btnStart.Add_Click({
    $urls = @($txtUrls.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
    if ($urls.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("請先輸入至少一條影片網址。", "Smart Downloader", "OK", "Information") | Out-Null
        return
    }

    if (-not (Get-YtDlpPath)) {
        [System.Windows.Forms.MessageBox]::Show("找不到 yt-dlp.exe。請把 yt-dlp.exe 放到此工具資料夾，或加入 Windows PATH。", "Smart Downloader", "OK", "Warning") | Out-Null
        return
    }

    $cookiePath = Resolve-CookiePath $txtCookies.Text
    if ($cookiePath -and -not (Test-Path $cookiePath)) {
        [System.Windows.Forms.MessageBox]::Show("找不到 Cookies 檔案：`r`n$cookiePath`r`n`r`n如果這個網站不需要登入，請把 Cookies 欄位清空再試。", "Smart Downloader", "OK", "Warning") | Out-Null
        return
    }

    New-Item -ItemType Directory -Force -Path $txtOutput.Text | Out-Null
    $Script:Jobs.Clear()
    $Script:Stopping = $false

    foreach ($url in $urls) {
        [void]$Script:Jobs.Add([PSCustomObject]@{
            Url = $url
            Status = "等待中"
            Process = $null
            LogPath = ""
            ErrPath = ""
            Error = ""
            Progress = 0
            Speed = ""
            Eta = ""
            Fragment = ""
        })
    }
    $status.Text = "已建立 $($urls.Count) 個下載任務"
    Refresh-List
    Start-NextDownloads
})

$btnStop.Add_Click({
    $Script:Stopping = $true
    foreach ($job in $Script:Jobs) {
        if ($job.Status -eq "等待中") {
            $job.Status = "已取消"
        }
        if ($job.Status -eq "下載中" -and $job.Process -and -not $job.Process.HasExited) {
            try { $job.Process.Kill() } catch {}
            $job.Status = "已停止"
        }
    }
    $status.Text = "已停止未完成任務"
    Refresh-List
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1200
$timer.Add_Tick({
    $changed = $false
    foreach ($job in $Script:Jobs) {
        if ($job.Status -eq "下載中") {
            if (Update-JobProgress $job) { $changed = $true }
        }

        if ($job.Status -eq "下載中" -and $job.Process -and $job.Process.HasExited) {
            [void](Update-JobProgress $job)
            if ($job.Process.ExitCode -eq 0) {
                $job.Status = "完成"
                $job.Progress = 100
                $job.Eta = "完成"
                $job.Error = ""
            } else {
                $summary = Get-LogSummary $job.ErrPath
                if ($summary -eq "記錄檔是空的" -or $summary -eq "沒有找到記錄檔") {
                    $summary = Get-LogSummary $job.LogPath
                }
                if ([double]$job.Progress -ge 99 -and $summary -notmatch "ERROR|HTTP Error|failed|Unable|unsupported|timed out|certificate|Private video|Sign in|cookies") {
                    $job.Status = "完成（有警告）"
                    $job.Progress = 100
                    $job.Eta = "完成"
                    $job.Error = $summary
                } else {
                    $job.Status = "失敗"
                    $job.Error = $summary
                }
            }
            $changed = $true
        }
    }

    Start-NextDownloads

    $running = ($Script:Jobs | Where-Object { $_.Status -eq "下載中" }).Count
    $done = ($Script:Jobs | Where-Object { $_.Status -eq "完成" -or $_.Status -eq "完成（有警告）" }).Count
    $failed = ($Script:Jobs | Where-Object { $_.Status -eq "失敗" }).Count
    $pending = ($Script:Jobs | Where-Object { $_.Status -eq "等待中" }).Count
    $visibleJob = @($Script:Jobs | Where-Object { $_.Status -eq "下載中" } | Select-Object -First 1)
    if ($visibleJob.Count -eq 0) {
        $visibleJob = @($Script:Jobs | Where-Object { $_.Progress -gt 0 } | Select-Object -Last 1)
    }
    if ($visibleJob.Count -gt 0) {
        $progress.Value = [Math]::Min(1000, [Math]::Max(0, [int]([double]$visibleJob[0].Progress * 10)))
    } else {
        $progress.Value = 0
    }

    if ($failed -gt 0) {
        $lastFailed = @($Script:Jobs | Where-Object { $_.Status -eq "失敗" } | Select-Object -Last 1)[0]
        $status.Text = "完成：$done｜失敗：$failed｜下載中：$running｜等待：$pending｜最近錯誤：$($lastFailed.Error)"
    } elseif ($running -gt 0 -and $visibleJob.Count -gt 0) {
        $active = $visibleJob[0]
        $status.Text = "完成：$done｜下載中：$running｜等待：$pending｜目前：$('{0:N1}' -f [double]$active.Progress)%｜速度：$($active.Speed)｜ETA：$($active.Eta)"
    } else {
        $status.Text = "完成：$done｜失敗：$failed｜下載中：$running｜等待：$pending"
    }

    if ($changed) { Refresh-List }
})
$timer.Start()

$form.Add_FormClosing({
    foreach ($job in $Script:Jobs) {
        if ($job.Status -eq "下載中" -and $job.Process -and -not $job.Process.HasExited) {
            try { $job.Process.Kill() } catch {}
        }
    }
})

[void]$form.ShowDialog()






