# ──────────────────────────────────────────────────────────────────────────────
#     __  ______  __    _____   ____ __
#    / / / / __ \/ /   /  _/ | / / //_/
#   / / / / /_/ / /    / //  |/ / ,<   
#  / /_/ / ____/ /____/ // /|  / /| |  
#  \____/_/   /_____/___/_/ |_/_/ |_|  
#                                      
#
#      __  ______    _   _____   ________________ 
#     /  |/  /   |  / | / /   | / ____/ ____/ __ \
#    / /|_/ / /| | /  |/ / /| |/ / __/ __/ / /_/ /
#   / /  / / ___ |/ /|  / ___ / /_/ / /___/ _, _/ 
#  /_/  /_/_/  |_/_/ |_/_/  |_\____/_____/_/ |_|  
#                                                 
# ──────────────────────────────────────────────────────────────────────────────
# Uplink Manager Installer
# Author: Sam Jage
# ──────────────────────────────────────────────────────────────────────────────

# ========== SELF‑ELEVATION BLOCK ==========
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}
# =========================================

# Force 64‑bit execution if running in 32‑bit mode
if ($env:PROCESSOR_ARCHITECTURE -ne "AMD64") {
    $powershell = "$env:WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    Start-Process $powershell -Verb RunAs -ArgumentList "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}
# =========================================

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# ── Version guard ─────────────────────────────────────────────────────────────
if ($PSVersionTable.PSVersion.Major -lt 5) {
    [System.Windows.MessageBox]::Show(
        "This installer requires PowerShell 5.1 or higher.`n`nCurrent version: $($PSVersionTable.PSVersion)",
        "Incompatible PowerShell Version",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    )
    exit 1
}

# ── Colors ────────────────────────────────────────────────────────────────────
$BG = "#252830"
$SURFACE = "#2e3038"
$PANEL = "#404450"
$YELLOW = "#fabd2f"
$GREEN = "#3d5c3f"
$GREEN_LT = "#5a7d5c"
$RED = "#fb4934"
$TEXT = "#ebdbb2"
$TEXT_MUTED = "#a89984"

# ── State ─────────────────────────────────────────────────────────────────────
$script:SelectedInternet = $null
$script:SelectedUplink = $null
$script:CurrentPage = 0
$script:NeedsReboot = $false
$script:InstallDir = "C:\Program Files\Uplink Manager"   # adjust if you use x86
$script:SpinnerTimer = $null
$script:SpinnerFrames = @("⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷")
$script:SpinnerIndex = 0
$script:ReqJob = $null
$script:PrereqJob = $null

# ── Helpers (unchanged from your original) ──
function Get-Vmxnet3Adapters {
    Get-NetAdapter | Where-Object { $_.InterfaceDescription -like "*vmxnet3*" -and $_.Status -eq "Up" } |
    Select-Object -ExpandProperty Name
}

function Start-BtnSpinner {
    if ($script:SpinnerTimer) { $script:SpinnerTimer.Stop() }
    $script:SpinnerIndex = 0
    $script:SpinnerTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:SpinnerTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $script:SpinnerTimer.Add_Tick({
            $script:SpinnerIndex = ($script:SpinnerIndex + 1) % $script:SpinnerFrames.Count
            $BtnNext.Content = $script:SpinnerFrames[$script:SpinnerIndex]
        })
    $BtnNext.IsEnabled = $false
    $script:SpinnerTimer.Start()
}

function Stop-BtnSpinner {
    if ($script:SpinnerTimer) { $script:SpinnerTimer.Stop(); $script:SpinnerTimer = $null }
    $BtnNext.IsEnabled = $true
    $BtnNext.Content = "Next →"
}

function Test-NatClass {
    try { Get-CimClass -Namespace root/StandardCimv2 -ClassName MSFT_NetNat -ErrorAction Stop | Out-Null; return $true }
    catch { return $false }
}

# ── XAML UI ───────────────────────────────────────────────────────────────────
[xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Uplink Manager Installer" Width="680" Height="580"
    WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
    Background="$BG" FontFamily="Consolas">
    <Window.Resources>
        <Style TargetType="{x:Type Button}">
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Button}">
                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Opacity" Value="0.75"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Opacity" Value="0.6"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="StepLabel" TargetType="TextBlock">
            <Setter Property="Foreground" Value="#a89984"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="Margin" Value="0,2,0,2"/>
        </Style>
        <Style x:Key="StatusDot" TargetType="Ellipse">
            <Setter Property="Width" Value="10"/>
            <Setter Property="Height" Value="10"/>
            <Setter Property="Margin" Value="0,0,8,0"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>
    </Window.Resources>
    <Grid Margin="0">
        <Grid.RowDefinitions>
            <RowDefinition Height="70"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="60"/>
        </Grid.RowDefinitions>
        <Border Grid.Row="0" Background="#1a1c24">
            <StackPanel VerticalAlignment="Center" Margin="24,0,0,0">
                <TextBlock Text="Uplink Manager" FontSize="20" FontWeight="Bold" Foreground="$YELLOW" FontFamily="Consolas"/>
                <TextBlock Text="Virtual Machine Setup Installer for Windows 11" FontSize="11" Foreground="$TEXT_MUTED" Margin="0,2,0,0"/>
            </StackPanel>
        </Border>
        <Grid Grid.Row="1" x:Name="PageContainer" Margin="0"/>
        <Border Grid.Row="2" Background="#1a1c24">
            <Grid Margin="24,0">
                <TextBlock x:Name="FooterStatus" VerticalAlignment="Center" Foreground="$TEXT_MUTED" FontSize="11" Text=""/>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                    <Button x:Name="BtnBack" Content="← Back" Width="100" Height="32"
                            Margin="0,0,8,0" Visibility="Collapsed"
                            Background="$SURFACE" Foreground="$TEXT" BorderBrush="$PANEL"/>
                    <Button x:Name="BtnNext" Content="Next →" Width="100" Height="32"
                            Background="$GREEN" Foreground="$TEXT" BorderBrush="$GREEN" FontWeight="Bold"/>
                </StackPanel>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# ── Set window icon ───────────────────────────────────────────────────────────
$iconPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "uplink_manager.ico"
if (-not $iconPath -or -not (Test-Path $iconPath)) { $iconPath = Join-Path $PSScriptRoot "uplink_manager.ico" }
if (Test-Path $iconPath) {
    $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([uri]$iconPath)
}

$PageContainer = $window.FindName("PageContainer")
$BtnNext = $window.FindName("BtnNext")
$BtnBack = $window.FindName("BtnBack")
$FooterStatus = $window.FindName("FooterStatus")

# ── UI Helpers ────────────────────────────────────────────────────────────────
function New-SectionTitle {
    param([string]$text)
    $tb = [System.Windows.Controls.TextBlock]::new()
    $tb.Text = $text; $tb.FontSize = 16; $tb.FontWeight = "Bold"
    $tb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($YELLOW)
    $tb.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    return $tb
}

function New-BodyText {
    param([string]$text, [object]$color = $TEXT_MUTED)
    $tb = [System.Windows.Controls.TextBlock]::new()
    $tb.Text = $text; $tb.FontSize = 12; $tb.TextWrapping = "Wrap"
    if ($color -is [System.Windows.Media.Brush]) {
        $tb.Foreground = $color
    }
    else {
        $tb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString([string]$color)
    }
    $tb.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    return $tb
}

function New-Separator {
    $sep = [System.Windows.Controls.Separator]::new()
    $sep.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($PANEL)
    $sep.Margin = [System.Windows.Thickness]::new(0, 8, 0, 12)
    return $sep
}

function New-CheckRow {
    param([string]$label, [bool]$passed, [string]$detail = "")
    $sp = [System.Windows.Controls.StackPanel]::new()
    $sp.Orientation = "Horizontal"; $sp.Margin = [System.Windows.Thickness]::new(0, 4, 0, 4)
    $dot = [System.Windows.Shapes.Ellipse]::new()
    $dot.Width = 10; $dot.Height = 10; $dot.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0); $dot.VerticalAlignment = "Center"
    $dot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString($(if ($passed) { $GREEN_LT } else { $RED }))
    $sp.Children.Add($dot) | Out-Null
    $tb = [System.Windows.Controls.TextBlock]::new()
    $tb.Text = "$(if ($passed) { '✔' } else { '✘' })  $label"; $tb.FontSize = 12; $tb.VerticalAlignment = "Center"
    $tb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($TEXT)
    $sp.Children.Add($tb) | Out-Null
    if ($detail) {
        $dtb = [System.Windows.Controls.TextBlock]::new()
        $dtb.Text = "  -  $detail"; $dtb.FontSize = 11; $dtb.VerticalAlignment = "Center"
        $dtb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($TEXT_MUTED)
        $sp.Children.Add($dtb) | Out-Null
    }
    return $sp
}

function New-StyledListBox {
    param([string[]]$items)
    $lb = [System.Windows.Controls.ListBox]::new()
    $lb.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#2e3038")
    $lb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#ebdbb2")
    $lb.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#404450")
    $lb.BorderThickness = [System.Windows.Thickness]::new(1)
    $lb.FontFamily = [System.Windows.Media.FontFamily]::new("Consolas")
    $lb.FontSize = 12; $lb.Height = 80
    $lb.Margin = [System.Windows.Thickness]::new(0, 4, 0, 12)
    [System.Windows.Controls.ScrollViewer]::SetHorizontalScrollBarVisibility($lb, [System.Windows.Controls.ScrollBarVisibility]::Disabled)
    $itemStyle = [System.Windows.Style]::new([System.Windows.Controls.ListBoxItem])
    $bgS = [System.Windows.Setter]::new(); $bgS.Property = [System.Windows.Controls.Control]::BackgroundProperty; $bgS.Value = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#2e3038"); $itemStyle.Setters.Add($bgS)
    $fgS = [System.Windows.Setter]::new(); $fgS.Property = [System.Windows.Controls.Control]::ForegroundProperty; $fgS.Value = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#ebdbb2"); $itemStyle.Setters.Add($fgS)
    $pdS = [System.Windows.Setter]::new(); $pdS.Property = [System.Windows.Controls.Control]::PaddingProperty; $pdS.Value = [System.Windows.Thickness]::new(8, 4, 8, 4); $itemStyle.Setters.Add($pdS)
    $hvT = [System.Windows.Trigger]::new(); $hvT.Property = [System.Windows.Controls.ListBoxItem]::IsMouseOverProperty; $hvT.Value = $true
    $hvBg = [System.Windows.Setter]::new(); $hvBg.Property = [System.Windows.Controls.Control]::BackgroundProperty; $hvBg.Value = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#fabd2f")
    $hvFg = [System.Windows.Setter]::new(); $hvFg.Property = [System.Windows.Controls.Control]::ForegroundProperty; $hvFg.Value = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#1e1e1e")
    $hvT.Setters.Add($hvBg); $hvT.Setters.Add($hvFg); $itemStyle.Triggers.Add($hvT)
    $slT = [System.Windows.Trigger]::new(); $slT.Property = [System.Windows.Controls.ListBoxItem]::IsSelectedProperty; $slT.Value = $true
    $slBg = [System.Windows.Setter]::new(); $slBg.Property = [System.Windows.Controls.Control]::BackgroundProperty; $slBg.Value = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#3d5c3f")
    $slFg = [System.Windows.Setter]::new(); $slFg.Property = [System.Windows.Controls.Control]::ForegroundProperty; $slFg.Value = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#ebdbb2")
    $slT.Setters.Add($slBg); $slT.Setters.Add($slFg); $itemStyle.Triggers.Add($slT)
    $suT = [System.Windows.MultiTrigger]::new()
    $sc1 = [System.Windows.Condition]::new(); $sc1.Property = [System.Windows.Controls.ListBoxItem]::IsSelectedProperty; $sc1.Value = $true
    $sc2 = [System.Windows.Condition]::new(); $sc2.Property = [System.Windows.Controls.ListBoxItem]::IsKeyboardFocusWithinProperty; $sc2.Value = $false
    $suT.Conditions.Add($sc1); $suT.Conditions.Add($sc2)
    $suBg = [System.Windows.Setter]::new(); $suBg.Property = [System.Windows.Controls.Control]::BackgroundProperty; $suBg.Value = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#3d5c3f")
    $suFg = [System.Windows.Setter]::new(); $suFg.Property = [System.Windows.Controls.Control]::ForegroundProperty; $suFg.Value = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#ebdbb2")
    $suT.Setters.Add($suBg); $suT.Setters.Add($suFg); $itemStyle.Triggers.Add($suT)
    $lb.ItemContainerStyle = $itemStyle
    foreach ($item in $items) { $lb.Items.Add($item) | Out-Null }
    return $lb
}

function Add-PassRow {
    param($panel, [string]$text)
    $row = [System.Windows.Controls.StackPanel]::new(); $row.Orientation = "Horizontal"; $row.Margin = [System.Windows.Thickness]::new(0, 4, 0, 4)
    $greenBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($GREEN_LT)
    $icon = [System.Windows.Controls.TextBlock]::new(); $icon.Text = "✔"; $icon.FontSize = 14; $icon.FontWeight = "Bold"
    $icon.Foreground = $greenBrush; $icon.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0); $icon.VerticalAlignment = "Center"; $row.Children.Add($icon) | Out-Null
    $txt = [System.Windows.Controls.TextBlock]::new(); $txt.Text = $text; $txt.FontSize = 12; $txt.VerticalAlignment = "Center"
    $txt.Foreground = $greenBrush; $row.Children.Add($txt) | Out-Null
    $panel.Children.Add($row) | Out-Null
}

function Add-FailBlock {
    param($panel, [string]$title, [string[]]$hints)
    $block = [System.Windows.Controls.StackPanel]::new(); $block.Orientation = "Vertical"; $block.Margin = [System.Windows.Thickness]::new(0, 4, 0, 8)
    $hdr = [System.Windows.Controls.StackPanel]::new(); $hdr.Orientation = "Horizontal"
    $icon = [System.Windows.Controls.TextBlock]::new(); $icon.Text = "🛑"; $icon.FontSize = 14; $icon.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0); $icon.VerticalAlignment = "Center"; $hdr.Children.Add($icon) | Out-Null
    $ttl = [System.Windows.Controls.TextBlock]::new(); $ttl.Text = $title; $ttl.FontSize = 12; $ttl.FontWeight = "Bold"; $ttl.VerticalAlignment = "Center"
    $ttl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($RED); $hdr.Children.Add($ttl) | Out-Null
    $block.Children.Add($hdr) | Out-Null
    foreach ($hint in $hints) {
        $h = [System.Windows.Controls.TextBlock]::new(); $h.Text = "    $hint"; $h.FontSize = 11; $h.Margin = [System.Windows.Thickness]::new(24, 2, 0, 0)
        $h.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($TEXT_MUTED); $block.Children.Add($h) | Out-Null
    }
    $panel.Children.Add($block) | Out-Null
}

# ── Page 0: Welcome ───────────────────────────────────────────────────────────
function Show-PageWelcome {
    $PageContainer.Children.Clear()
    $sp = [System.Windows.Controls.StackPanel]::new()
    $sp.Margin = [System.Windows.Thickness]::new(32, 24, 32, 0)
    $sp.Children.Add((New-SectionTitle "Welcome to Uplink Manager Setup")) | Out-Null
    $sp.Children.Add((New-Separator)) | Out-Null
    $sp.Children.Add((New-BodyText "This installer will configure your Windows 11 Pro VM to run Uplink Manager — a tool for engineers to set up network address translation from an internet-facing adapter to a downstream NAT Uplink adapter.")) | Out-Null
    $sp.Children.Add((New-BodyText "The following will be configured on this VM:")) | Out-Null
    foreach ($step in @(
            "Rename selected adapters to Internet VLAN and NAT Uplink",
            "Enable Hyper-V Services (required for WinNAT)",
            "Register Windows NAT WMI provider (netttcim.dll)",
            "Install Uplink Manager to $($script:InstallDir)",
            "Create desktop shortcut"
        )) {
        $row = [System.Windows.Controls.StackPanel]::new(); $row.Orientation = "Horizontal"; $row.Margin = [System.Windows.Thickness]::new(8, 3, 0, 3)
        $dot = [System.Windows.Shapes.Ellipse]::new(); $dot.Width = 6; $dot.Height = 6; $dot.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0); $dot.VerticalAlignment = "Center"
        $dot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString($YELLOW); $row.Children.Add($dot) | Out-Null
        $tb = [System.Windows.Controls.TextBlock]::new(); $tb.Text = $step; $tb.FontSize = 12
        $tb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($TEXT); $row.Children.Add($tb) | Out-Null
        $sp.Children.Add($row) | Out-Null
    }
    $sp.Children.Add((New-Separator)) | Out-Null
    $sp.Children.Add((New-BodyText "Before continuing, ensure this VM has at least 2 vmxnet3 adapters and hardware virtualization (Expose VT-x to guest) is enabled in VM processor settings." $TEXT_MUTED)) | Out-Null
    $PageContainer.Children.Add($sp) | Out-Null
    $BtnBack.Visibility = "Collapsed"
    $BtnNext.Content = "Begin Setup →"; $BtnNext.IsEnabled = $true
    $BtnNext.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($GREEN)
    $FooterStatus.Text = "Step 1 of 6"
}

# ── Page 1: Pre-Installation Requirements ────────────────────────────────────
function Show-PageRequirements {
    $PageContainer.Children.Clear()
    $sp = [System.Windows.Controls.StackPanel]::new()
    $sp.Margin = [System.Windows.Thickness]::new(32, 24, 32, 0)
    $sp.Children.Add((New-SectionTitle "Pre-Installation Requirements")) | Out-Null
    $sp.Children.Add((New-Separator)) | Out-Null
    $sp.Children.Add((New-BodyText "Checking VM configuration...")) | Out-Null
    $script:ReqResultsPanel = [System.Windows.Controls.StackPanel]::new()
    $sp.Children.Add($script:ReqResultsPanel) | Out-Null
    $sp.Children.Add((New-Separator)) | Out-Null
    $script:ReqWarning = New-BodyText "" $RED
    $sp.Children.Add($script:ReqWarning) | Out-Null
    $PageContainer.Children.Add($sp) | Out-Null
    $BtnBack.Visibility = "Visible"; $BtnNext.IsEnabled = $false
    $FooterStatus.Text = "Step 2 of 6"

    $script:ReqJob = Start-Job -ScriptBlock {
        $virtOk = $false
        # Check if a hypervisor is present (most reliable)
        try {
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            if ($cs.HypervisorPresent -eq $true) { $virtOk = $true }
        }
        catch {}
        # If not detected, check if Hyper‑V feature is installed
        if (-not $virtOk) {
            try {
                $hyperV = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Platform -ErrorAction SilentlyContinue
                if ($hyperV.State -eq "Enabled") { $virtOk = $true }
            }
            catch {}
        }
        # Optionally check Virtualization‑Based Security registry (indicates hypervisor)
        if (-not $virtOk) {
            try {
                $reg = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard" -Name "EnableVirtualizationBasedSecurity" -ErrorAction SilentlyContinue
                if ($reg.EnableVirtualizationBasedSecurity -eq 1) { $virtOk = $true }
            }
            catch {}
        }
        $adapters = @(Get-NetAdapter | Where-Object { $_.InterfaceDescription -like "*vmxnet3*" -and $_.Status -eq "Up" } | Select-Object -ExpandProperty Name)
        [PSCustomObject]@{ VirtOk = $virtOk; Adapters = $adapters; AdapterOk = $adapters.Count -ge 2 }
    }

    $window.Dispatcher.Invoke({
            $script:timerTickReq = 0
            $script:pollTimerReq = [System.Windows.Threading.DispatcherTimer]::new()
            $script:pollTimerReq.Interval = [TimeSpan]::FromMilliseconds(400)
            $script:pollTimerReq.Tag = $script:ReqJob
            $script:pollTimerReq.Add_Tick({
                    $script:timerTickReq++
                    if ($script:timerTickReq -gt 38) {
                        $script:pollTimerReq.Stop()
                        $script:ReqWarning.Text = "⚠  Check timed out after ~15 seconds. Please restart the installer."
                        Stop-BtnSpinner; $BtnNext.IsEnabled = $false; return
                    }
                    $job = $script:pollTimerReq.Tag
                    if ($null -eq $job) {
                        $script:pollTimerReq.Stop()
                        $script:ReqWarning.Text = "⚠  Background check could not be tracked. Please restart the installer."
                        Stop-BtnSpinner; $BtnNext.IsEnabled = $false; return
                    }
                    if ($job.State -in "Completed", "Failed", "Stopped") {
                        $script:pollTimerReq.Stop()
                        $result = $null
                        try { $result = Receive-Job -Job $job -ErrorAction Stop }
                        catch { $script:ReqWarning.Text = "⚠  Failed to retrieve job result: $($_.Exception.Message)" }
                        finally { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue; $script:ReqJob = $null; $script:pollTimerReq.Tag = $null }

                        if ($null -eq $result) {
                            $script:ReqWarning.Text = "⚠  Background check returned no data. Please restart the installer."
                            Stop-BtnSpinner; $BtnNext.IsEnabled = $false
                            $BtnNext.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($PANEL)
                        }
                        else {
                            if ($result.VirtOk) {
                                Add-PassRow $script:ReqResultsPanel "Hardware virtualization exposed to guest OS"
                            }
                            else {
                                Add-FailBlock $script:ReqResultsPanel "Hardware virtualization not detected" @(
                                    "— Shutdown this VM",
                                    "— In VMware: VM Settings → Processors",
                                    "— Enable: Expose hardware assisted virtualization to the guest OS"
                                )
                            }
                            if ($result.AdapterOk) {
                                Add-PassRow $script:ReqResultsPanel "vmxnet3 adapters detected  —  $($result.Adapters.Count) found"
                            }
                            else {
                                Add-FailBlock $script:ReqResultsPanel "Insufficient vmxnet3 adapters  —  $($result.Adapters.Count) found (minimum 2 required)" @(
                                    "— Shutdown this VM",
                                    "— In VMware: VM Settings → Network Adapters",
                                    "— Add at least 2 vmxnet3 network adapters"
                                )
                            }
                            $listBlock = [System.Windows.Controls.StackPanel]::new(); $listBlock.Margin = [System.Windows.Thickness]::new(24, 4, 0, 0)
                            foreach ($adapter in $result.Adapters) {
                                $r = [System.Windows.Controls.TextBlock]::new(); $r.Text = "· $adapter"; $r.FontSize = 11; $r.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
                                $r.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($TEXT_MUTED); $listBlock.Children.Add($r) | Out-Null
                            }
                            $script:ReqResultsPanel.Children.Add($listBlock) | Out-Null
                            $allOk = $result.VirtOk -and $result.AdapterOk
                            if (-not $allOk) { $script:ReqWarning.Text = "⚠  Resolve the issues above before continuing. Shutdown the VM if required." }
                            Stop-BtnSpinner
                            if (-not $allOk) {
                                $BtnNext.IsEnabled = $false
                                $BtnNext.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($PANEL)
                            }
                            else {
                                $BtnNext.IsEnabled = $true; $BtnNext.Content = "Next →"
                                $BtnNext.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($GREEN)
                            }
                        }
                    }
                })
            $script:pollTimerReq.Start()
        })
}

# ── Page 2: VM Prerequisites ──────────────────────────────────────────────────
function Show-PagePrereqs {
    $PageContainer.Children.Clear()
    $sp = [System.Windows.Controls.StackPanel]::new()
    $sp.Margin = [System.Windows.Thickness]::new(32, 24, 32, 0)
    $sp.Children.Add((New-SectionTitle "VM Prerequisites Check")) | Out-Null
    $sp.Children.Add((New-Separator)) | Out-Null
    $sp.Children.Add((New-BodyText "Verifying this VM meets requirements for Uplink Manager...")) | Out-Null
    $script:PrereqResultsPanel = [System.Windows.Controls.StackPanel]::new()
    $sp.Children.Add($script:PrereqResultsPanel) | Out-Null
    $sp.Children.Add((New-Separator)) | Out-Null
    $script:PrereqWarning = New-BodyText "" $RED
    $sp.Children.Add($script:PrereqWarning) | Out-Null
    $PageContainer.Children.Add($sp) | Out-Null
    $BtnBack.Visibility = "Visible"; $BtnNext.IsEnabled = $false
    $FooterStatus.Text = "Step 3 of 6"

    $script:PrereqJob = Start-Job -ScriptBlock {
        $adminOk = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $osVer = [System.Environment]::OSVersion.Version
        $winOk = $osVer.Major -ge 10
        $adapters = @(Get-NetAdapter | Where-Object { $_.InterfaceDescription -like "*vmxnet3*" -and $_.Status -eq "Up" } | Select-Object -ExpandProperty Name)
        $adapterOk = $adapters.Count -ge 2
        # Reliable virtualization detection
        $virtOk = $false
        try {
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            if ($cs.HypervisorPresent -eq $true) { $virtOk = $true }
        }
        catch {}
        if (-not $virtOk) {
            try {
                $hyperV = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Platform -ErrorAction SilentlyContinue
                if ($hyperV.State -eq "Enabled") { $virtOk = $true }
            }
            catch {}
        }
        if (-not $virtOk) {
            try {
                $reg = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard" -Name "EnableVirtualizationBasedSecurity" -ErrorAction SilentlyContinue
                if ($reg.EnableVirtualizationBasedSecurity -eq 1) { $virtOk = $true }
            }
            catch {}
        }
        [PSCustomObject]@{ AdminOk = $adminOk; WinOk = $winOk; OsBuild = $osVer.Build; AdapterOk = $adapterOk; AdCount = $adapters.Count; VirtOk = $virtOk }
    }

    $window.Dispatcher.Invoke({
            $script:timerTickPrereq = 0
            $script:pollTimerPrereq = [System.Windows.Threading.DispatcherTimer]::new()
            $script:pollTimerPrereq.Interval = [TimeSpan]::FromMilliseconds(400)
            $script:pollTimerPrereq.Tag = $script:PrereqJob
            $script:pollTimerPrereq.Add_Tick({
                    $script:timerTickPrereq++
                    if ($script:timerTickPrereq -gt 38) {
                        $script:pollTimerPrereq.Stop()
                        $script:PrereqWarning.Text = "⚠  Prerequisite check timed out after ~15 seconds."
                        Stop-BtnSpinner; $BtnNext.IsEnabled = $false; return
                    }
                    $job = $script:pollTimerPrereq.Tag
                    if ($null -eq $job) {
                        $script:pollTimerPrereq.Stop()
                        $script:PrereqWarning.Text = "⚠  Prerequisite check could not be tracked. Please restart the installer."
                        Stop-BtnSpinner; $BtnNext.IsEnabled = $false; return
                    }
                    if ($job.State -in "Completed", "Failed", "Stopped") {
                        $script:pollTimerPrereq.Stop()
                        $r = $null
                        try { $r = Receive-Job -Job $job -ErrorAction Stop }
                        catch { $script:PrereqWarning.Text = "⚠  Failed to retrieve prerequisite check result: $($_.Exception.Message)" }
                        finally { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue; $script:PrereqJob = $null; $script:pollTimerPrereq.Tag = $null }

                        if ($null -eq $r) {
                            $script:PrereqWarning.Text = "⚠  Prerequisite check returned no data. Please restart the installer."
                            Stop-BtnSpinner; $BtnNext.IsEnabled = $false
                            $BtnNext.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($PANEL)
                        }
                        else {
                            $script:PrereqResultsPanel.Children.Add((New-CheckRow "Running as Administrator" $r.AdminOk)) | Out-Null
                            $script:PrereqResultsPanel.Children.Add((New-CheckRow "Windows 10/11 detected" $r.WinOk "Build $($r.OsBuild)")) | Out-Null
                            $script:PrereqResultsPanel.Children.Add((New-CheckRow "At least 2 vmxnet3 adapters present" $r.AdapterOk "$($r.AdCount) found")) | Out-Null
                            $script:PrereqResultsPanel.Children.Add((New-CheckRow "Hardware virtualization exposed to VM" $r.VirtOk $(if (-not $r.VirtOk) { "Enable in VMware VM Settings → Processors" } else { "" }))) | Out-Null
                            $allOk = $r.AdminOk -and $r.WinOk -and $r.AdapterOk
                            if (-not $allOk) {
                                $script:PrereqWarning.Text = "⚠  One or more checks failed. Please resolve the issues above before continuing."
                            }
                            else {
                                $script:PrereqResultsPanel.Children.Add((New-BodyText "✔  All critical checks passed. You may continue." $GREEN_LT)) | Out-Null
                            }
                            Stop-BtnSpinner
                            if (-not $allOk) {
                                $BtnNext.IsEnabled = $false
                                $BtnNext.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($PANEL)
                            }
                            else {
                                $BtnNext.IsEnabled = $true; $BtnNext.Content = "Next →"
                                $BtnNext.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($GREEN)
                            }
                        }
                    }
                })
            $script:pollTimerPrereq.Start()
        })
}

# ── Page 3: Adapter selection ─────────────────────────────────────────────────
function Show-PageAdapters {
    $PageContainer.Children.Clear()
    $sp = [System.Windows.Controls.StackPanel]::new()
    $sp.Margin = [System.Windows.Thickness]::new(32, 24, 32, 0)
    $sp.Children.Add((New-SectionTitle "Configure Network Adapters")) | Out-Null
    $sp.Children.Add((New-Separator)) | Out-Null
    $sp.Children.Add((New-BodyText "Select which adapter serves each role. They will be renamed to match what Uplink Manager expects.")) | Out-Null
    $adapters = Get-Vmxnet3Adapters
    $tb1 = New-BodyText "Internet-facing adapter  (WAN uplink — receives internet from your network)"
    $tb1.FontWeight = "Bold"; $tb1.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($TEXT); $sp.Children.Add($tb1) | Out-Null
    $script:ComboInternet = New-StyledListBox $adapters
    if ($script:SelectedInternet) { $script:ComboInternet.SelectedItem = $script:SelectedInternet }
    $sp.Children.Add($script:ComboInternet) | Out-Null
    $tb2 = New-BodyText "NAT Uplink adapter  (downstream — connects to devices that need internet)"
    $tb2.FontWeight = "Bold"; $tb2.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($TEXT); $sp.Children.Add($tb2) | Out-Null
    $script:ComboUplink = New-StyledListBox $adapters
    if ($script:SelectedUplink) { $script:ComboUplink.SelectedItem = $script:SelectedUplink }
    $sp.Children.Add($script:ComboUplink) | Out-Null
    $sp.Children.Add((New-Separator)) | Out-Null
    $script:AdapterWarning = New-BodyText "" $RED; $sp.Children.Add($script:AdapterWarning) | Out-Null
    $sp.Children.Add((New-BodyText "After selection, these adapters will be renamed:  Internet VLAN  and  NAT Uplink" $TEXT_MUTED)) | Out-Null
    $PageContainer.Children.Add($sp) | Out-Null
    $BtnBack.Visibility = "Visible"
    $BtnNext.Content = "Next →"; $BtnNext.IsEnabled = $true
    $BtnNext.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($GREEN)
    $FooterStatus.Text = "Step 4 of 6"
    Stop-BtnSpinner
}

# ── Page 4: Confirm ───────────────────────────────────────────────────────────
function Show-PageConfirm {
    $PageContainer.Children.Clear()
    $sp = [System.Windows.Controls.StackPanel]::new()
    $sp.Margin = [System.Windows.Thickness]::new(32, 24, 32, 0)
    $sp.Children.Add((New-SectionTitle "Confirm Installation")) | Out-Null
    $sp.Children.Add((New-Separator)) | Out-Null
    $sp.Children.Add((New-BodyText "The following changes will be made to this VM:")) | Out-Null
    foreach ($action in @(
            "Rename '$($script:SelectedInternet)' → Internet VLAN",
            "Rename '$($script:SelectedUplink)' → NAT Uplink",
            "Enable Hyper-V Services (may require reboot)",
            "Register netttcim.dll WMI provider",
            "Compile netttcim.mof WMI class definitions",
            "Create desktop shortcut (no arrow overlay)"
        )) {
        $row = [System.Windows.Controls.StackPanel]::new(); $row.Orientation = "Horizontal"; $row.Margin = [System.Windows.Thickness]::new(8, 4, 0, 4)
        $dot = [System.Windows.Shapes.Ellipse]::new(); $dot.Width = 6; $dot.Height = 6; $dot.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0); $dot.VerticalAlignment = "Center"
        $dot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString($YELLOW); $row.Children.Add($dot) | Out-Null
        $tb = [System.Windows.Controls.TextBlock]::new(); $tb.Text = $action; $tb.FontSize = 12
        $tb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($TEXT); $row.Children.Add($tb) | Out-Null
        $sp.Children.Add($row) | Out-Null
    }
    $sp.Children.Add((New-Separator)) | Out-Null
    $PageContainer.Children.Add($sp) | Out-Null
    $BtnBack.Visibility = "Visible"
    $BtnNext.Content = "⚡  Install"; $BtnNext.IsEnabled = $true
    $BtnNext.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($GREEN)
    $FooterStatus.Text = "Step 5 of 6"
    Stop-BtnSpinner
}

# ── Page 5: Install ───────────────────────────────────────────────────────────
function Show-PageInstall {
    $PageContainer.Children.Clear()
    $BtnBack.Visibility = "Collapsed"
    $sp = [System.Windows.Controls.StackPanel]::new()
    $sp.Margin = [System.Windows.Thickness]::new(32, 24, 32, 0)

    # Section title that we will update later
    $script:installTitle = New-SectionTitle "Installing..."
    $sp.Children.Add($script:installTitle) | Out-Null
    $sp.Children.Add((New-Separator)) | Out-Null

    $script:LogBox = [System.Windows.Controls.TextBlock]::new()
    $script:LogBox.FontSize = 11
    $script:LogBox.FontFamily = [System.Windows.Media.FontFamily]::new("Consolas")
    $script:LogBox.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($TEXT_MUTED)
    $script:LogBox.TextWrapping = "Wrap"; $script:LogBox.Text = ""

    $scroll = [System.Windows.Controls.ScrollViewer]::new()
    $scroll.Height = 290
    $scroll.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Hidden   # hides vertical scroll bar
    $scroll.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Disabled # prevents horizontal scroll bar
    $scroll.Content = $script:LogBox
    $scroll.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($SURFACE)
    $scroll.Padding = [System.Windows.Thickness]::new(8)

    $sp.Children.Add($scroll) | Out-Null
    $PageContainer.Children.Add($sp) | Out-Null
    $FooterStatus.Text = "Step 6 of 6  —  Installing..."

    # Create a temporary log file
    $script:LogFilePath = Join-Path $env:TEMP "uplink_install_log_$pid.txt"
    if (Test-Path $script:LogFilePath) { Remove-Item $script:LogFilePath -Force }

    # Start background job that writes to the log file
    $script:InstallJob = Start-Job -Name "UplinkInstall" -ScriptBlock {
        param($SelectedInternet, $SelectedUplink, $InstallDir, $LogFilePath)

        function Write-LogLine { param($Line) $Line | Out-File -FilePath $LogFilePath -Append -Encoding UTF8 }

        $ok = $true
        $needsReboot = $false

        Write-LogLine "── Configuring Network Adapters ────────────────────"
        try {
            Rename-NetAdapter -Name $SelectedInternet -NewName "Internet VLAN" -ErrorAction Stop
            Write-LogLine "  ✔  Renamed '$SelectedInternet' → 'Internet VLAN'"
        } catch {
            Write-LogLine "  ✘  Failed to rename Internet adapter: $_"
            $ok = $false
        }
        try {
            Rename-NetAdapter -Name $SelectedUplink -NewName "NAT Uplink" -ErrorAction Stop
            Write-LogLine "  ✔  Renamed '$SelectedUplink' → 'NAT Uplink'"
        } catch {
            Write-LogLine "  ✘  Failed to rename NAT Uplink adapter: $_"
            $ok = $false
        }

        Write-LogLine "── Enabling Hyper-V Services ────────────────────────"
        try {
            $proc = Start-Process -FilePath "dism.exe" -ArgumentList "/online /enable-feature /featurename:Microsoft-Hyper-V-Services /all /quiet /norestart" -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
                $needsReboot = $true
                Write-LogLine "  ✔  Hyper-V Services enabled (reboot required)"
            } else {
                Write-LogLine "  ✘  Failed to enable Hyper-V Services, DISM exit code: $($proc.ExitCode)"
                $ok = $false
            }
        } catch {
            Write-LogLine "  ✘  Failed to enable Hyper-V Services: $_"
            $ok = $false
        }

        Write-LogLine "── Registering WMI NAT Provider ─────────────────────"
        $dllPath = "C:\Windows\System32\wbem\netttcim.dll"
        $mofPath = "C:\Windows\System32\wbem\netttcim.mof"
        if (Test-Path $dllPath) {
            try {
                $reg = Start-Process -FilePath "regsvr32.exe" -ArgumentList "/s `"$dllPath`"" -Wait -PassThru
                if ($reg.ExitCode -eq 0) { Write-LogLine "  ✔  Registered netttcim.dll" } else { Write-LogLine "  ⚠  regsvr32 returned $($reg.ExitCode)" }
            } catch { Write-LogLine "  ✘  Failed to register DLL: $_" }
        } else { Write-LogLine "  ✘  netttcim.dll not found"; $ok = $false }

        if (Test-Path $mofPath) {
            try {
                $mof = Start-Process -FilePath "mofcomp.exe" -ArgumentList "`"$mofPath`"" -Wait -PassThru
                if ($mof.ExitCode -eq 0) { Write-LogLine "  ✔  Compiled netttcim.mof" } else { Write-LogLine "  ⚠  mofcomp returned $($mof.ExitCode)" }
            } catch { Write-LogLine "  ✘  Failed to compile MOF: $_" }
        } else { Write-LogLine "  ✘  netttcim.mof not found"; $ok = $false }

        try {
            Restart-Service winmgmt -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2
            try { Get-CimClass -Namespace root/StandardCimv2 -ClassName MSFT_NetNat -ErrorAction Stop | Out-Null; $natOk = $true } catch { $natOk = $false }
            if ($natOk) { Write-LogLine "  ✔  MSFT_NetNat WMI class verified" }
            else { Write-LogLine "  ✔  MSFT_NetNat will be available after reboot (expected)"; $needsReboot = $true }
        } catch { Write-LogLine "  ⚠  Could not restart WMI service" }

        Write-LogLine "── Verifying Uplink Manager ────────────────────────────"
        $exeDest = Join-Path $InstallDir "Uplink Manager.exe"
        if (Test-Path $exeDest) {
            Write-LogLine "  ✔  Uplink Manager.exe verified in $InstallDir"
        } else {
            Write-LogLine "  ✘  Uplink Manager.exe missing from $InstallDir"
            $ok = $false
        }

        Write-LogLine "── Creating Logs Folder ─────────────────────────────"
        $logsDir = Join-Path $InstallDir "logs"
        try {
            if (-not (Test-Path $logsDir)) {
                New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
                Write-LogLine "  ✔  Created logs folder: $logsDir"
            } else {
                Write-LogLine "  ✔  Logs folder already exists: $logsDir"
            }
        } catch {
            Write-LogLine "  ⚠  Could not create logs folder: $_"
        }

        Write-LogLine "── Creating Desktop Shortcut ────────────────────────"
        try {
            $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons"
            if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
            Set-ItemProperty -Path $regPath -Name "29" -Value "%SystemRoot%\System32\imageres.dll,197" -Type String -Force
            Write-LogLine "  ✔  Shortcut arrow overlay removed"
            $shortcutPath = [System.IO.Path]::Combine([Environment]::GetFolderPath("Desktop"), "Uplink Manager.lnk")
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $exeDest
            $shortcut.WorkingDirectory = $InstallDir
            $shortcut.Description = "Uplink Manager"
            $shortcut.Save()
            Write-LogLine "  ✔  Desktop shortcut created"
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500
        } catch { Write-LogLine "  ⚠  Shortcut creation issue: $_" }

        Write-LogLine ""
        if ($ok) {
            Write-LogLine "✔  Installation complete!"
            if ($needsReboot) { Write-LogLine "⚠  A reboot is required to finalize Hyper-V Services and WMI changes." }
        } else {
            Write-LogLine "⚠  Installation completed with errors. Review log above."
        }

        # Mark completion and reboot status
        Write-LogLine "___INSTALL_COMPLETE___"
        if ($needsReboot) { Write-LogLine "___REBOOT_REQUIRED___" } else { Write-LogLine "___NO_REBOOT___" }
    } -ArgumentList $script:SelectedInternet, $script:SelectedUplink, $script:InstallDir, $script:LogFilePath

    # Timer to tail the log file
    $script:lastFileSize = 0
    $script:installPollTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:installPollTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:installPollTimer.Add_Tick({
        if (-not (Test-Path $script:LogFilePath)) { return }
        $fs = [System.IO.File]::Open($script:LogFilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $fs.Seek($script:lastFileSize, [System.IO.SeekOrigin]::Begin) | Out-Null
        $reader = [System.IO.StreamReader]::new($fs)
        $newLines = $reader.ReadToEnd()
        $script:lastFileSize = $fs.Position
        $reader.Close()
        $fs.Close()

        if ($newLines) {
            $script:LogBox.Text += $newLines
            $script:LogBox.UpdateLayout()
        }

        # Check for completion marker
        if ($newLines -like "*___INSTALL_COMPLETE___*") {
            $script:installPollTimer.Stop()
            $job = Get-Job -Name "UplinkInstall" -ErrorAction SilentlyContinue
            if ($job) { Receive-Job -Job $job; Remove-Job -Job $job -Force }
            # Clean up log file
            if (Test-Path $script:LogFilePath) { Remove-Item $script:LogFilePath -Force }

            # Determine if reboot is needed from the log
            $needsReboot = $newLines -like "*___REBOOT_REQUIRED___*"
            $script:NeedsReboot = $needsReboot

            # Update UI
            Stop-BtnSpinner
            if ($needsReboot) {
                $script:installTitle.Text = "Installed – Please Reboot"
                $BtnNext.Content = "Reboot Now"
                $FooterStatus.Text = "Done – Reboot required"
            } else {
                $script:installTitle.Text = "Installation Complete"
                $BtnNext.Content = "Finish"
                $FooterStatus.Text = "Done"
            }
            $BtnNext.IsEnabled = $true
            $BtnNext.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($GREEN)
            $script:CurrentPage = 5
        }
    })
    $script:installPollTimer.Start()
}

# ── Navigation ────────────────────────────────────────────────────────────────
$BtnNext.Add_Click({
        Start-BtnSpinner
        switch ($script:CurrentPage) {
            0 { $script:CurrentPage = 1; Show-PageRequirements }
            1 { $script:CurrentPage = 2; Show-PagePrereqs }
            2 { $script:CurrentPage = 3; Show-PageAdapters }
            3 {
                $internet = $script:ComboInternet.SelectedItem
                $uplink = $script:ComboUplink.SelectedItem
                if (-not $internet -or -not $uplink) {
                    $script:AdapterWarning.Text = "⚠  Please select both adapters before continuing."
                    Stop-BtnSpinner; return
                }
                if ($internet -eq $uplink) {
                    $script:AdapterWarning.Text = "⚠  Internet and NAT Uplink adapters must be different."
                    Stop-BtnSpinner; return
                }
                $script:SelectedInternet = $internet; $script:SelectedUplink = $uplink
                $script:CurrentPage = 4; Show-PageConfirm
            }
            4 { $script:CurrentPage = 5; Show-PageInstall }
            5 { if ($script:NeedsReboot) { Restart-Computer -Force } else { $window.Close() } }
        }
    })

$BtnBack.Add_Click({
        switch ($script:CurrentPage) {
            1 { $script:CurrentPage = 0; Show-PageWelcome }
            2 { $script:CurrentPage = 1; Show-PageRequirements }
            3 { $script:CurrentPage = 2; Show-PagePrereqs }
            4 { $script:CurrentPage = 3; Show-PageAdapters }
        }
    })

# ── Launch ────────────────────────────────────────────────────────────────────
Show-PageWelcome
$window.ShowDialog() | Out-Null