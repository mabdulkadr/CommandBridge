<#!
.SYNOPSIS
    Remote Script Executor GUI - Execute PowerShell commands across multiple remote Windows devices.

.DESCRIPTION
    This script provides a WPF-based graphical user interface to execute custom PowerShell
    commands across multiple remote targets concurrently. It features Ping and WSMan pre-checks,
    alternative credentials support, real-time status tracking, and output logging.

    Requires Administrator privileges or appropriate WinRM permissions on target devices.

    Notes:
    - Script automatically restarts in STA mode if required for WPF.
    - Supports importing target devices via CSV.
    - Logs and outputs are saved to C:\ProgramData\CommandBridge\Logs\

.EXAMPLE
    .\CommandBridge.ps1
    Launches the GUI for interactive remote command execution.

.NOTES
    Author      : Mohammad Abdelkader Omar
    Website     : https://momar.tech
    LinkedIn    : https://www.linkedin.com/in/mabdulkadr/
    Date        : 2026-05-18
    Version     : 2.0
    Changelog   :
                 2.0 - Rebuilt UI with enhanced styling, and optimized concurrency.
                 1.5 - Added custom branding and hyperlink support.
                 1.0 - Initial release.
#>

# Ensure script runs in STA mode required for WPF
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $PSCommandPath
    exit
}

# Load essential GUI assemblies
#region ======================== ASSEMBLIES ============================
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase | Out-Null
Add-Type -AssemblyName System.Windows.Forms | Out-Null
#endregion

# Initialize system variables and app state
#region ======================== STATE MANAGEMENT ============================
$Script:AppState = @{
    AppTitle        = 'Command Bridge'
    AppVersion      = 'v2.0'
    Brand           = 'momar.tech'
    BasePath        = (Join-Path $env:ProgramData 'CommandBridge')
    Paths           = @{}
    LogFile         = ''
    UiLogQueue      = [System.Collections.Generic.Queue[object]]::new()
    Jobs            = [System.Collections.ArrayList]::new()
    Queue           = [System.Collections.Generic.Queue[object]]::new()
    TargetRows      = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
    InputTargets    = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
    RowMap          = @{}
    LastResults     = @()
    PoolMax         = 32
    Pool            = $null
    AltCredential   = $null
    TotalTargets    = 0
    DoneCount       = 0
    IsRunning       = $false
    MaxConcurrent   = 8
    CancelRequested = $false
    UiTimer         = $null
    LogFlushTimer   = $null
    MaxLogBlocks    = 1000
    Worker          = ''
    Window          = $null
    Controls        = @{}
}

# Create required directory paths
$Script:AppState.Paths = @{
  Root    = $Script:AppState.BasePath
  Logs    = Join-Path $Script:AppState.BasePath 'Logs'
  Temp    = Join-Path $Script:AppState.BasePath 'Temp'
  Outputs = Join-Path $Script:AppState.BasePath 'Logs\Outputs'
}

$Script:AppState.Paths.GetEnumerator() | ForEach-Object {
  if (-not (Test-Path -LiteralPath $_.Value)) { New-Item -ItemType Directory -Path $_.Value -Force | Out-Null }
}

# Define main log file path
$Script:AppState.LogFile = Join-Path $Script:AppState.Paths.Logs ("CommandBridge_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
#endregion

# UI Helpers & Logging
#region ======================== UI HELPERS & LOGGING ============================

# Convert text to WPF Brush
function New-Brush {
  param([string]$Color)
  try {
    $bc = New-Object Windows.Media.BrushConverter
    return $bc.ConvertFromString($Color)
  } catch {
    return $null
  }
}

# Write message to log file
function Write-LogFile {
  param(
    [string]$Message,
    [string]$Level = 'INFO'
  )
  try {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath $Script:AppState.LogFile -Value ("[{0}] [{1}] {2}" -f $ts, $Level, $Message)
  } catch {}
}

# Determine log color/type based on level
function Get-LogMeta {
  param([string]$Level)
  $label = 'INFO '
  $color = '#E5E7EB'

  switch ($Level) {
    'SUCCESS' { $label = 'OK   '; $color = '#0A8A0A' }
    'WARN'    { $label = 'WARN '; $color = '#B58900' }
    'ERROR'   { $label = 'ERR  '; $color = '#D13438' }
    'FAIL'    { $label = 'FAIL '; $color = '#D13438' }
    'START'   { $label = 'START'; $color = '#60A5FA' }
    'DONE'    { $label = 'DONE '; $color = '#34D399' }
    'DIVIDER' { $label = '-----'; $color = '#9CA3AF' }
    default   { $label = 'INFO '; $color = '#E5E7EB' }
  }

  return [pscustomobject]@{ Label = $label; Color = $color }
}

# Format log line for UI display
function Format-UiLogLine {
  param(
    [string]$Message,
    [string]$Level,
    [string]$Prefix
  )

  $ts = Get-Date -Format 'HH:mm:ss'
  $meta = Get-LogMeta -Level $Level

  if ([string]::IsNullOrWhiteSpace($Prefix)) {
    $head = "[{0}] [{1}] {2}" -f $ts, $meta.Label, $Message
  } else {
    $head = "[{0}] [{1}] [{2}] {3}" -f $ts, $meta.Label, $Prefix, $Message
  }

  $lines = $head -split "`r?`n"
  if ($lines.Count -le 1) {
    return [pscustomobject]@{ Lines = @($head); Color = $meta.Color; Level = $Level }
  }

  $out = New-Object System.Collections.Generic.List[string]
  $out.Add($lines[0]) | Out-Null
  for ($i = 1; $i -lt $lines.Count; $i++) {
    $out.Add(("           " + $lines[$i])) | Out-Null
  }

  return [pscustomobject]@{ Lines = $out.ToArray(); Color = $meta.Color; Level = $Level }
}

# Enqueue log for printing
function Enqueue-UiLog {
  param(
    [string]$Message,
    [ValidateSet('INFO','SUCCESS','WARN','ERROR','FAIL','START','DONE','DIVIDER')]
    [string]$Level = 'INFO',
    [string]$Prefix = ''
  )

  try {
    $fmt = Format-UiLogLine -Message $Message -Level $Level -Prefix $Prefix
    $fileLine = $fmt.Lines[0]
    Write-LogFile -Message $fileLine -Level $Level

    foreach ($ln in $fmt.Lines) {
      $Script:AppState.UiLogQueue.Enqueue([pscustomobject]@{
          Line  = $ln
          Color = $fmt.Color
      })
    }
  } catch {}
}

# Flush log queue and print to UI
function Flush-UiLog {
  if (-not $Script:AppState.Window -or -not $Script:AppState.Controls['rtb'] -or -not $Script:AppState.UiLogQueue) { return }
  if ($Script:AppState.UiLogQueue.Count -eq 0) { return }

  $batch = New-Object System.Collections.ArrayList
  $maxPerTick = 120
  for ($i = 0; $i -lt $maxPerTick; $i++) {
    if ($Script:AppState.UiLogQueue.Count -eq 0) { break }
    [void]$batch.Add($Script:AppState.UiLogQueue.Dequeue())
  }

  $Script:AppState.Window.Dispatcher.Invoke([action]{
    $rtb = $Script:AppState.Controls['rtb']
    foreach ($b in $batch) {
      $run = New-Object Windows.Documents.Run ($b.Line)
      $run.Foreground = New-Brush $b.Color

      $p = New-Object Windows.Documents.Paragraph
      $p.Margin = '0,0,0,2'
      [void]$p.Inlines.Add($run)

      $rtb.Document.Blocks.Add($p)
    }
    
    # UI Performance: Trim blocks to prevent memory/render leaks
    while ($rtb.Document.Blocks.Count -gt $Script:AppState.MaxLogBlocks) {
        $rtb.Document.Blocks.Remove($rtb.Document.Blocks.FirstBlock)
    }
    
    $rtb.ScrollToEnd()
  })
}

# Update Progress bar
function Set-Progress {
  param([int]$Value, [int]$Max)
  if (-not $Script:AppState.Controls['pb'] -or -not $Script:AppState.Window) { return }
  $Script:AppState.Window.Dispatcher.Invoke([action]{
    $Script:AppState.Controls['pb'].Maximum = [double]([Math]::Max(1, $Max))
    $Script:AppState.Controls['pb'].Value   = [double]([Math]::Max(0, $Value))
  })
}
#endregion

# Data Model & Grid
#region ======================== DATA MODEL & GRID ============================

# Create new device row with Index
function New-DeviceRow([int]$Index, [string]$Device) {
  New-Object PSObject -Property @{
    Index       = $Index
    Device      = $Device
    State       = 'Queued'
    LastMessage = ''
  }
}

# Update device row status
function Update-DeviceRow {
  param(
    [hashtable]$RowMap,
    [string]$Device,
    [string]$State,
    [string]$LastMessage
  )
  if (-not $RowMap.ContainsKey($Device)) { return }

  $r = $RowMap[$Device]
  if ($State) { $r.State = $State }
  if ($LastMessage) { $r.LastMessage = $LastMessage }

  if ($Script:AppState.Controls['dgStatus']) {
    $Script:AppState.Window.Dispatcher.Invoke([action] { $Script:AppState.Controls['dgStatus'].Items.Refresh() })
  }
}
#endregion

# Credential Dialog
#region ======================== CREDENTIAL DIALOG ============================
function Show-CredentialDialog {
  param(
    [string]$Title = 'Alternate Credentials',
    [string]$Hint = 'Enter credentials for remote execution.'
  )

  $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Width="520" SizeToContent="Height"
        WindowStartupLocation="CenterOwner" Background="#FFF5F7FB" FontFamily="Segoe UI">
  <Grid Margin="14">
    <Border Padding="16" CornerRadius="5" Background="White" BorderBrush="#E5E7EB" BorderThickness="1">
      <StackPanel>
        <TextBlock Text="$Hint" Foreground="#374151" Margin="0,0,0,10"/>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="110"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="10"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Grid.Column="0" Text="User:" VerticalAlignment="Center"/>
          <TextBox   Grid.Row="0" Grid.Column="1" x:Name="TxtUser" Height="30" Padding="5"/>
          <TextBlock Grid.Row="2" Grid.Column="0" Text="Password:" VerticalAlignment="Center"/>
          <PasswordBox Grid.Row="2" Grid.Column="1" x:Name="TxtPass" Height="30" Padding="5"/>
        </Grid>
        <TextBlock x:Name="LblErr" Foreground="#D13438" Margin="0,10,0,0" TextWrapping="Wrap"/>
        <Grid Margin="0,14,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Button Grid.Column="0" x:Name="BtnOk" Content="OK" Height="38" Margin="0,0,8,0" Background="#2563EB" Foreground="White" BorderBrush="#2563EB" FontWeight="SemiBold"/>
          <Button Grid.Column="1" x:Name="BtnCancel" Content="Cancel" Height="38" Background="#E5E7EB" BorderBrush="#CBD5E1"/>
        </Grid>
      </StackPanel>
    </Border>
  </Grid>
</Window>
"@

  $w = [Windows.Markup.XamlReader]::Parse($x)
  $w.Owner = $Script:AppState.Window

  $TxtUser   = $w.FindName('TxtUser')
  $TxtPass   = $w.FindName('TxtPass')
  $LblErr    = $w.FindName('LblErr')
  $BtnOk     = $w.FindName('BtnOk')
  $BtnCancel = $w.FindName('BtnCancel')
  $result = $null

  $BtnOk.Add_Click({
    $LblErr.Text = ''
    if ([string]::IsNullOrWhiteSpace($TxtUser.Text)) { $LblErr.Text = 'User is required.'; return }
    if ([string]::IsNullOrWhiteSpace($TxtPass.Password)) { $LblErr.Text = 'Password is required.'; return }

    $sec = ConvertTo-SecureString $TxtPass.Password -AsPlainText -Force
    $result = New-Object System.Management.Automation.PSCredential ($TxtUser.Text, $sec)
    $w.DialogResult = $true
    $w.Close()
  })

  $BtnCancel.Add_Click({ $w.DialogResult = $false; $w.Close() })

  $dialogResult = $w.ShowDialog()
  if ($dialogResult -eq $true) {
    if (-not $result -and -not [string]::IsNullOrWhiteSpace($TxtUser.Text) -and -not [string]::IsNullOrWhiteSpace($TxtPass.Password)) {
      try {
        $sec = ConvertTo-SecureString $TxtPass.Password -AsPlainText -Force
        $result = New-Object System.Management.Automation.PSCredential ($TxtUser.Text, $sec)
      } catch {}
    }
    return $result
  }

  return $null
}
#endregion

# Runspace Pool & Worker
#region ======================== RUNSPACE POOL & WORKER ============================
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$Script:AppState.Pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $Script:AppState.PoolMax, $iss, $Host)
$Script:AppState.Pool.ApartmentState = [System.Threading.ApartmentState]::STA
$Script:AppState.Pool.Open()

# The worker scriptblock executed for each target
$Script:AppState.Worker = @'
param(
  [string]$Computer,
  [string]$CustomText,
  [bool]$DoPing,
  [bool]$DoWsman,
  [bool]$UseCred,
  [pscredential]$Cred,
  [int]$TimeoutSec = 120
)

# Packages a remote execution result into a JSON string for the calling runspace.
function Out-Result($state,$msg,$out){
  [pscustomobject]@{
    Computer=$Computer
    State=$state
    Message=$msg
    Output=$out
  } | ConvertTo-Json -Compress
}

try {
  if([string]::IsNullOrWhiteSpace($Computer)){ return (Out-Result 'Failed' 'Empty computer name.' $null) }

  if($DoPing){
    $ok = $false
    try {
      $ping = New-Object System.Net.NetworkInformation.Ping
      $reply = $ping.Send($Computer, 4000)
      $ok = ($reply.Status -eq 'Success')
      $ping.Dispose()
    } catch { $ok = $false }
    if(-not $ok){ return (Out-Result 'Failed' 'Ping failed.' $null) }
  }

  if($DoWsman){
    $ok2 = $false
    try {
      $wso = New-PSSessionOption -OperationTimeout 15000 -CancelTimeout 5000 -OpenTimeout 15000
      if($UseCred -and $Cred){
        $wsSess = New-PSSession -ComputerName $Computer -Credential $Cred -SessionOption $wso -ErrorAction Stop
      } else {
        $wsSess = New-PSSession -ComputerName $Computer -SessionOption $wso -ErrorAction Stop
      }
      Remove-PSSession $wsSess -ErrorAction SilentlyContinue
      $ok2 = $true
    } catch { $ok2 = $false }
    if(-not $ok2){ return (Out-Result 'Failed' 'WSMan test failed (WinRM not reachable).' $null) }
  }

  $sb = $null
  $mode = ''
  if(-not [string]::IsNullOrWhiteSpace($CustomText)){
    $mode = 'Command'
    $sb = [scriptblock]::Create($CustomText)
  } else {
    return (Out-Result 'Failed' 'No command provided.' $null)
  }

  $opTimeout = $TimeoutSec * 1000
  if ($opTimeout -lt 10000) { $opTimeout = 10000 }
  $sessionOption = New-PSSessionOption -OperationTimeout $opTimeout -CancelTimeout 10000 -IdleTimeout ($opTimeout * 2) -OpenTimeout 30000
  $invokeParams = @{
    ComputerName  = $Computer
    ScriptBlock   = $sb
    SessionOption = $sessionOption
    ErrorAction   = 'Stop'
  }
  if($UseCred -and $Cred){ $invokeParams.Credential = $Cred }

  $output = Invoke-Command @invokeParams 2>&1 | Out-String
  if([string]::IsNullOrWhiteSpace($output)){ $output = "$mode completed with no output." }

  return (Out-Result 'Success' "$mode executed successfully." $output)
}
catch {
  $m = "[{0}] {1}" -f $_.FullyQualifiedErrorId, $_.Exception.Message
  if([string]::IsNullOrWhiteSpace($m)){ $m = 'Unknown error.' }
  return (Out-Result 'Failed' $m $null)
}
'@

# Start remote task and add to job list
function Start-RemoteTask {
  param(
    [string]$Computer,
    [string]$CustomText,
    [bool]$DoPing,
    [bool]$DoWsman,
    [bool]$UseCred,
    [pscredential]$Cred,
    [int]$TimeoutSec = 120
  )

  try {
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.RunspacePool = $Script:AppState.Pool

    $null = $ps.AddScript($Script:AppState.Worker).
      AddArgument($Computer).
      AddArgument($CustomText).
      AddArgument([bool]$DoPing).
      AddArgument([bool]$DoWsman).
      AddArgument([bool]$UseCred).
      AddArgument($Cred).
      AddArgument([int]$TimeoutSec)

    $async = $ps.BeginInvoke()

    $job = [pscustomobject]@{
      Computer = $Computer
      PS       = $ps
      Async    = $async
      Started  = Get-Date
    }
    [void]$Script:AppState.Jobs.Add($job)
    return $true
  } catch {
    return $false
  }
}
#endregion

# Main Window XAML
#region ======================== XAML - MAIN WINDOW ============================
$Xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="CommandBridge" Width="1200" Height="905"
        WindowStartupLocation="CenterScreen" Background="#F6F8FB"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True" SnapsToDevicePixels="True">

  <Window.Resources>
    <DropShadowEffect x:Key="ShadowPrimary" BlurRadius="10" ShadowDepth="0" Opacity="0.55" Color="#9FAEF7"/>
    <DropShadowEffect x:Key="ShadowBlue" BlurRadius="10" ShadowDepth="0" Opacity="0.55" Color="#8FB4FF"/>
    <DropShadowEffect x:Key="ShadowGreen" BlurRadius="10" ShadowDepth="0" Opacity="0.55" Color="#9FD7B8"/>
    <DropShadowEffect x:Key="ShadowRed" BlurRadius="10" ShadowDepth="0" Opacity="0.55" Color="#F7C4C4"/>

    <Style x:Key="CenterText" TargetType="TextBlock">
      <Setter Property="HorizontalAlignment" Value="Center"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <Style x:Key="BtnBase" TargetType="Button">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border CornerRadius="3" Background="{TemplateBinding Background}" BorderThickness="0">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsEnabled" Value="False">
          <Setter Property="Effect" Value="{x:Null}"/>
          <Setter Property="Background" Value="#ECEFF3"/>
          <Setter Property="Foreground" Value="#9CA3AF"/>
          <Setter Property="Opacity" Value="0.75"/>
          <Setter Property="Cursor" Value="Arrow"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="Button" BasedOn="{StaticResource BtnBase}"/>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#9FAEF7"/>
      <Setter Property="Foreground" Value="#1F2D3A"/>
      <Setter Property="Effect" Value="{StaticResource ShadowPrimary}"/>
    </Style>
    <Style x:Key="BtnBlue" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#8FB4FF"/>
      <Setter Property="Foreground" Value="#1F2D3A"/>
      <Setter Property="Effect" Value="{StaticResource ShadowBlue}"/>
    </Style>
    <Style x:Key="BtnGreen" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#9FD7B8"/>
      <Setter Property="Foreground" Value="#1F2D3A"/>
      <Setter Property="Effect" Value="{StaticResource ShadowGreen}"/>
    </Style>
    <Style x:Key="BtnRed" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#F7C4C4"/>
      <Setter Property="Foreground" Value="#1F2D3A"/>
      <Setter Property="Effect" Value="{StaticResource ShadowRed}"/>
    </Style>
    
    <SolidColorBrush x:Key="SidebarCardBackground" Color="#F9FBFF"/>
    <SolidColorBrush x:Key="SidebarCardBorder" Color="#E4E9F0"/>
    <Style x:Key="SidebarCard" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource SidebarCardBackground}"/>
      <Setter Property="BorderBrush" Value="{StaticResource SidebarCardBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="5"/>
      <Setter Property="Padding" Value="12"/>
      <Setter Property="Margin" Value="12,10,12,0"/>
    </Style>
    <Style x:Key="SidebarTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#0F172A"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style x:Key="SidebarText" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#4B5563"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Padding" Value="6"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Background" Value="#F9FBFF"/>
      <Setter Property="BorderBrush" Value="#E4E9F0"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border CornerRadius="4" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ScrollViewer x:Name="PART_ContentHost" Margin="0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsFocused" Value="True">
                <Setter Property="BorderBrush" Value="#8FB4FF"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="270"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <TextBlock Name="txtLogPath" Visibility="Collapsed" />

    <Border Grid.Column="0" Background="#FFFFFF" BorderBrush="#E6EBF4" BorderThickness="0,0,1,0">
      <DockPanel LastChildFill="True">

        <StackPanel DockPanel.Dock="Top" Margin="18,18,18,12">
          <StackPanel Orientation="Horizontal">
            <Border Width="36" Height="36" Background="#9AB8FF" CornerRadius="6">
              <TextBlock Text="CB" Foreground="#1F2D3A" FontSize="18" FontWeight="Bold" VerticalAlignment="Center" HorizontalAlignment="Center"/>
            </Border>
            <StackPanel Margin="10,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="Command Bridge" FontSize="16" FontWeight="SemiBold" Foreground="#1F2D3A"/>
              <TextBlock Text="Remote Script Executor" FontSize="11" Foreground="#5F6B7A"/>
            </StackPanel>
          </StackPanel>
        </StackPanel>

        <Border DockPanel.Dock="Bottom" BorderBrush="#E6EBF4" BorderThickness="0,1,0,0" Padding="14" Background="#FFFFFF">
          <StackPanel>
            <TextBlock Text="Command Bridge" FontSize="13" FontWeight="Bold" Foreground="#1F2D3A"/>
            <TextBlock Text="Version 2.0" FontSize="11" Foreground="#5F6B7A" Margin="0,4,0,0"/>
            <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
              <TextBlock FontSize="11" Foreground="#7C8BA1" Text="© 2025 "/>
              <TextBlock Name="FooterLink" Text="Mohammad Omar" FontSize="11" Foreground="#2563EB" Cursor="Hand" TextDecorations="Underline"/>
            </StackPanel>
          </StackPanel>
        </Border>

        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="8,8">
            <TextBlock Text="EXECUTION" Margin="14,10,0,6" FontSize="11" FontWeight="SemiBold" Foreground="#7C8BA1"/>
            <Button Name="btnRun" Content="Run Execution" Height="38" Margin="6" Padding="12,0" Style="{StaticResource BtnPrimary}"/>
            <Button Name="btnCancel" Content="Cancel Run" Height="38" Margin="6" Padding="12,0" Style="{StaticResource BtnRed}"/>

            <Border Style="{StaticResource SidebarCard}">
              <StackPanel>
                <TextBlock Text="Session Status" Style="{StaticResource SidebarTitle}"/>
                <Grid Margin="0,4,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Grid.Column="0" Text="State:" Style="{StaticResource SidebarText}" FontWeight="SemiBold" Foreground="#111827" Margin="0,0,6,4"/>
                  <Border Grid.Row="0" Grid.Column="1" Background="#EEF2FF" Padding="6,2" CornerRadius="4" Margin="0,0,0,4">
                    <TextBlock Name="txtRuntime" Text="Idle" Style="{StaticResource SidebarText}" Foreground="#1D4ED8"/>
                  </Border>
                </Grid>
                <ProgressBar Name="pb" Height="8" Margin="0,6,0,0" BorderThickness="0" Background="#E4E9F0" Foreground="#8FB4FF"/>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource SidebarCard}">
              <StackPanel>
                <TextBlock Text="Settings &amp; Pre-checks" Style="{StaticResource SidebarTitle}"/>
                <Grid Margin="0,4,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="8"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="8"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="8"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="8"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="8"/>
                    <RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Grid.Column="0" Text="Ping Check" Style="{StaticResource SidebarText}" VerticalAlignment="Center"/>
                  <CheckBox Name="chkPing" Grid.Row="0" Grid.Column="1" IsChecked="True" VerticalAlignment="Center"/>
                  <TextBlock Grid.Row="2" Grid.Column="0" Text="WSMan Check" Style="{StaticResource SidebarText}" VerticalAlignment="Center"/>
                  <CheckBox Name="chkWsman" Grid.Row="2" Grid.Column="1" IsChecked="True" VerticalAlignment="Center"/>
                  <TextBlock Grid.Row="4" Grid.Column="0" Text="Alt Credentials" Style="{StaticResource SidebarText}" VerticalAlignment="Center"/>
                  <CheckBox Name="chkAltCred" Grid.Row="4" Grid.Column="1" IsChecked="False" VerticalAlignment="Center"/>
                  <TextBlock Grid.Row="6" Grid.Column="0" Text="Save Output" Style="{StaticResource SidebarText}" VerticalAlignment="Center"/>
                  <CheckBox Name="chkSaveOutput" Grid.Row="6" Grid.Column="1" IsChecked="False" VerticalAlignment="Center"/>
                  <TextBlock Grid.Row="8" Grid.Column="0" Text="Max Threads" Style="{StaticResource SidebarText}" VerticalAlignment="Center"/>
                  <TextBox Name="txtMaxConcurrent" Grid.Row="8" Grid.Column="1" Text="8" Width="40" TextAlignment="Center" Padding="2"/>
                  <TextBlock Grid.Row="10" Grid.Column="0" Text="Timeout (sec)" Style="{StaticResource SidebarText}" VerticalAlignment="Center"/>
                  <TextBox Name="txtTimeout" Grid.Row="10" Grid.Column="1" Text="120" Width="40" TextAlignment="Center" Padding="2"/>
                </Grid>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource SidebarCard}" Margin="12,10,12,10">
              <StackPanel>
                <TextBlock Text="Current Identity" Style="{StaticResource SidebarTitle}"/>
                <Border Background="#ECFDF3" Padding="6,4" CornerRadius="4">
                  <TextBlock Name="txtCredStatus" Text="Current user" Style="{StaticResource SidebarText}" Foreground="#166534"/>
                </Border>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource SidebarCard}" Margin="12,70,12,0">
              <StackPanel>
                <TextBlock Text="About this assistant" FontSize="12" FontWeight="SemiBold" Foreground="#1F2D3A" Margin="0,0,0,6"/>
                <TextBlock TextWrapping="Wrap" Foreground="#475467" FontSize="12" Text="A lightweight GUI toolkit for deploying PowerShell commands across multiple remote Windows endpoints."/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>
      </DockPanel>
    </Border>

    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <Border Grid.Row="0" Padding="15,14,15,8" Background="#ffffffff" CornerRadius="5" BorderBrush="#E4E9F0" BorderThickness="1" Margin="13,10,13,10">
        <StackPanel>
          <TextBlock Text="Welcome" FontSize="20" FontWeight="Bold" Foreground="#1F2D3A"/>
          <TextBlock Text="Manage endpoints and deploy execution commands across your network" FontSize="14" Foreground="#5F6B7A" Margin="0,6,0,0"/>
        </StackPanel>
      </Border>

      <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="13,0,13,13">

          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="1.7*"/>
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" Background="#ffffffff" CornerRadius="5" BorderBrush="#E4E9F0" BorderThickness="1" Padding="10" Margin="0,0,5,10">
              <StackPanel>
                <TextBlock Text="Remote PCs" FontSize="13" FontWeight="SemiBold" Foreground="#0F172A" Margin="0,0,0,8"/>
                <Grid Margin="0,0,0,6">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBox Name="txtSingleTarget" Grid.Column="0" Height="28" Margin="0,0,4,0" Padding="4,0" VerticalContentAlignment="Center"/>
                  <Button Name="btnAddTarget" Grid.Column="1" Content="Add" Width="45" Height="28" Margin="0,0,4,0" Style="{StaticResource BtnBase}" Background="#E4E9F0"/>
                  <Button Name="btnPasteTargets" Grid.Column="2" Content="Paste" Width="45" Height="28" Style="{StaticResource BtnBase}" Background="#E4E9F0"/>
                </Grid>
                <ListBox Name="lstTargets" ScrollViewer.VerticalScrollBarVisibility="Auto" MinHeight="130" Height="150" BorderBrush="#E4E9F0" BorderThickness="1" Background="#F9FBFF">
                  <ListBox.ItemTemplate>
                    <DataTemplate>
                      <CheckBox IsChecked="{Binding IsChecked, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Content="{Binding Device}" VerticalContentAlignment="Center" Margin="0,2"/>
                    </DataTemplate>
                  </ListBox.ItemTemplate>
                </ListBox>
                <Grid Margin="0,8,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Button Name="btnImportCsv" Grid.Column="0" Content="Import CSV" Height="28" Margin="0,0,4,0" Style="{StaticResource BtnBlue}"/>
                  <Button Name="btnClearTargets" Grid.Column="1" Content="Clear List" Height="28" Margin="2,0,2,0" Style="{StaticResource BtnBase}" Background="#E4E9F0"/>
                  <Button Name="btnOpenLogs" Grid.Column="2" Content="View Logs" Height="28" Margin="4,0,0,0" Style="{StaticResource BtnBase}" Background="#E4E9F0"/>
                </Grid>
              </StackPanel>
            </Border>

            <Border Grid.Column="1" Background="#ffffffff" CornerRadius="5" BorderBrush="#E4E9F0" BorderThickness="1" Padding="14" Margin="5,0,0,10">
              <StackPanel>
                <TextBlock Text="Execution Command" FontSize="14" FontWeight="SemiBold" Foreground="#0F172A" Margin="0,0,0,12"/>
                <TextBlock Text="Enter your PowerShell commands below:" FontSize="12" Foreground="#4B5563" Margin="0,0,0,4"/>
                <TextBox Name="txtCustom" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap" FontFamily="Consolas" MinHeight="160" Height="160" VerticalContentAlignment="Top"/>
              </StackPanel>
            </Border>
          </Grid>

          <Border Background="#ffffffff" CornerRadius="5" BorderBrush="#E4E9F0" BorderThickness="1" Padding="10" Margin="0,0,0,10">
            <StackPanel>
              <Grid Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*" />
                  <ColumnDefinition Width="Auto" />
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Device Status" FontSize="13" FontWeight="SemiBold" Foreground="#0F172A" VerticalAlignment="Center"/>
                <Button Name="btnExportCsv" Grid.Column="1" Content="Export CSV" Height="26" MinWidth="80" Style="{StaticResource BtnBase}" Background="#E4E9F0"/>
              </Grid>
              
              <DataGrid Name="dgStatus" Height="160" AutoGenerateColumns="False" CanUserAddRows="False" IsReadOnly="True" HeadersVisibility="Column" GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#E4E9F0" RowHeight="28" ColumnHeaderHeight="30" BorderBrush="#E4E9F0" Background="White">
                <DataGrid.RowStyle>
                  <Style TargetType="DataGridRow">
                    <Style.Triggers>
                      <DataTrigger Binding="{Binding State}" Value="Success">
                        <Setter Property="Background" Value="#E6FFE6" />
                      </DataTrigger>
                      <DataTrigger Binding="{Binding State}" Value="Failed">
                        <Setter Property="Background" Value="#FFE6E6" />
                      </DataTrigger>
                    </Style.Triggers>
                  </Style>
                </DataGrid.RowStyle>
                <DataGrid.Columns>
                  <DataGridTextColumn Header="#" Binding="{Binding Index}" Width="35" ElementStyle="{StaticResource CenterText}"/>
                  <DataGridTextColumn Header="Device" Binding="{Binding Device}" Width="*"/>
                  <DataGridTextColumn Header="State" Binding="{Binding State}" Width="150"/>
                  <DataGridTextColumn Header="Last Message" Binding="{Binding LastMessage}" Width="2.5*"/>
                </DataGrid.Columns>
              </DataGrid>
            </StackPanel>
          </Border>

          <Border Background="#ffffffff" CornerRadius="5" BorderBrush="#E4E9F0" BorderThickness="1" Padding="8">
            <StackPanel>
              <Grid Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Text="MESSAGE CENTER" FontSize="13" FontWeight="SemiBold" Foreground="#0F172A" VerticalAlignment="Center"/>
                <Button Name="btnCopyOutput" Grid.Column="1" Content="Copy Output" Height="26" MinWidth="120" Margin="0,0,8,0" Style="{StaticResource BtnGreen}"/>
                <Button Name="btnClearOutput" Grid.Column="2" Content="Clear" Height="26" MinWidth="70" Style="{StaticResource BtnBase}" Background="#E4E9F0"/>
              </Grid>
              <RichTextBox Name="rtb" Height="200" IsReadOnly="True" Background="#1F2D3A" Foreground="#E4E9F0" BorderBrush="#1F2937" BorderThickness="1" FontFamily="Consolas" FontSize="13" VerticalScrollBarVisibility="Auto" Padding="10"/>
            </StackPanel>
          </Border>

        </StackPanel>
      </ScrollViewer>

    </Grid>
  </Grid>
</Window>
"@
#endregion

# Load XAML
#region ======================== XAML LOAD ============================
try { $Script:AppState.Window = [Windows.Markup.XamlReader]::Parse($Xaml) }
catch { Write-Host "FAILED to load XAML: $($_.Exception.Message)" -ForegroundColor Red; throw }
#endregion

# Bind Controls
#region ======================== BIND CONTROLS ============================
$controls = @(
  'txtLogPath', 'txtSingleTarget', 'btnAddTarget', 'btnPasteTargets', 'lstTargets', 'btnClearTargets', 'btnImportCsv', 'btnOpenLogs', 'txtCustom',
  'chkPing', 'chkWsman', 'chkAltCred', 'txtCredStatus', 'txtMaxConcurrent', 'chkSaveOutput', 'txtTimeout',
  'dgStatus', 'btnRun', 'btnCancel', 'txtRuntime', 'btnCopyOutput', 'btnClearOutput', 'rtb', 'pb',
  'FooterLink', 'btnExportCsv'
)

foreach ($c in $controls) {
  $Script:AppState.Controls[$c] = $Script:AppState.Window.FindName($c)
}

$Script:AppState.Controls['rtb'].Document = New-Object Windows.Documents.FlowDocument
$Script:AppState.Controls['lstTargets'].ItemsSource = $Script:AppState.InputTargets
$Script:AppState.Controls['txtLogPath'].Text = $Script:AppState.LogFile
$Script:AppState.Window.Title = "$($Script:AppState.AppTitle) $($Script:AppState.AppVersion)"

if ($Script:AppState.Controls['FooterLink']) {
    $Script:AppState.Controls['FooterLink'].Add_MouseLeftButtonDown({
        try {
            Start-Process "https://www.linkedin.com/in/mabdulkadr/" -ErrorAction Stop
        } catch {
            Enqueue-UiLog "Failed to open link: $($_.Exception.Message)" "ERROR"
        }
    })
}

$Script:AppState.Controls['dgStatus'].ItemsSource = $Script:AppState.TargetRows
#endregion

# Alt Cred Helpers
#region ======================== ALT CRED HELPERS ============================
function Set-AltCredStatus {
  param([pscredential]$Cred)

  $ctrl = $Script:AppState.Controls['txtCredStatus']
  if ($ctrl) {
    if ($Cred) {
      $ctrl.Text    = $Cred.UserName
      $ctrl.ToolTip = "Alt credentials: $($Cred.UserName)"
    } else {
      $ctrl.Text    = 'Current user'
      $ctrl.ToolTip = 'Will use current user'
    }
  }
}
#endregion

# Target Parsing
#region ======================== TARGET PARSING ============================
function Add-TargetToList([string]$Device) {
  $clean = $Device.Trim()
  if ([string]::IsNullOrWhiteSpace($clean)) { return }
  
  $exists = $false
  foreach ($item in $Script:AppState.InputTargets) {
    if ($item.Device -eq $clean) { $exists = $true; break }
  }
  if (-not $exists) {
    $obj = New-Object PSObject
    $obj | Add-Member -MemberType NoteProperty -Name "Device" -Value $clean
    $obj | Add-Member -MemberType NoteProperty -Name "IsChecked" -Value $true
    $Script:AppState.InputTargets.Add($obj)
  }
}

# Returns only the checked/selected device names from the input target list.
function Get-SelectedTargets {
  $list = New-Object System.Collections.ArrayList
  foreach ($item in $Script:AppState.InputTargets) {
    if ($item.IsChecked) {
      [void]$list.Add($item.Device)
    }
  }
  return , $list.ToArray()
}
#endregion

# Input Mode Control
#region ======================== INPUT MODE CONTROL ============================
function Refresh-InputMode {
  $isRunning = $Script:AppState.IsRunning
  $enabled = -not $isRunning
  $opacity = if ($isRunning) { 0.55 } else { 1.0 }

  $controls = @('txtCustom', 'txtSingleTarget', 'btnAddTarget', 'btnPasteTargets', 'lstTargets', 'btnImportCsv', 'btnClearTargets', 'chkPing', 'chkWsman', 'chkAltCred', 'txtMaxConcurrent', 'txtTimeout')
  
  foreach ($c in $controls) {
    if ($Script:AppState.Controls[$c]) {
        $Script:AppState.Controls[$c].IsEnabled = $enabled
        $Script:AppState.Controls[$c].Opacity = $opacity
    }
  }
  
  if ($Script:AppState.Controls['btnRun']) { $Script:AppState.Controls['btnRun'].IsEnabled = $enabled }
  if ($Script:AppState.Controls['btnCancel']) { $Script:AppState.Controls['btnCancel'].IsEnabled = $isRunning }
}
#endregion

# Timers
#region ======================== TIMERS (LOG FLUSH & JOB POLL) ============================
$Script:AppState.LogFlushTimer = New-Object Windows.Threading.DispatcherTimer
$Script:AppState.LogFlushTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$Script:AppState.LogFlushTimer.Add_Tick({ try { Flush-UiLog } catch {} })

$Script:AppState.UiTimer = New-Object Windows.Threading.DispatcherTimer
$Script:AppState.UiTimer.Interval = [TimeSpan]::FromMilliseconds(250)
#endregion

# Imports & Exports
#region ======================== IMPORTS & EXPORTS ============================
$Script:AppState.Controls['btnAddTarget'].Add_Click({
  $txt = $Script:AppState.Controls['txtSingleTarget'].Text
  Add-TargetToList -Device $txt
  $Script:AppState.Controls['txtSingleTarget'].Text = ''
})

$Script:AppState.Controls['btnPasteTargets'].Add_Click({
  try {
    $clip = [System.Windows.Clipboard]::GetText()
    if (-not [string]::IsNullOrWhiteSpace($clip)) {
      $items = $clip.Split("`r", "`n", ",", ";")
      foreach ($item in $items) { Add-TargetToList -Device $item }
    }
  } catch { Enqueue-UiLog "Failed to paste from clipboard." "ERROR" }
})

$Script:AppState.Controls['btnClearTargets'].Add_Click({
  $Script:AppState.InputTargets.Clear()
})

$Script:AppState.Controls['btnOpenLogs'].Add_Click({
  try {
    if (Test-Path -LiteralPath $Script:AppState.Paths.Logs) {
      Start-Process -FilePath "explorer.exe" -ArgumentList "`"$($Script:AppState.Paths.Logs)`"" | Out-Null
    }
  } catch {
    Enqueue-UiLog ("Open logs failed: " + $_.Exception.Message) "ERROR"
  }
})

$Script:AppState.Controls['btnImportCsv'].Add_Click({
  try {
    if ($Script:AppState.IsRunning) { Enqueue-UiLog "Cannot import CSV while running." "WARN"; return }

    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Select CSV with targets'
    $dlg.Filter = 'CSV|*.csv|All files|*.*'

    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $csv = Import-Csv -LiteralPath $dlg.FileName
    if (-not $csv) { Enqueue-UiLog "CSV is empty." "WARN"; return }

    $headers = $csv[0].PSObject.Properties.Name
    $col = $null
    foreach ($h in @('Computer', 'Device', 'Name', 'Hostname', 'Target')) {
      if ($headers -contains $h) { $col = $h; break }
    }
    if (-not $col) { Enqueue-UiLog "CSV must contain a column named Computer/Device/Name/Hostname/Target." "ERROR"; return }

    $targets = @()
    foreach ($r in $csv) {
      $v = [string]$r.$col
      if (-not [string]::IsNullOrWhiteSpace($v)) { $targets += $v.Trim() }
    }
    if ($targets.Count -eq 0) { Enqueue-UiLog "No targets found in CSV." "WARN"; return }

    foreach ($t in $targets) { Add-TargetToList -Device $t }
    Enqueue-UiLog ("Imported and added target(s) from CSV.") "SUCCESS"
  }
  catch { Enqueue-UiLog ("CSV import error: " + $_.Exception.Message) "ERROR" }
})

# Export Event
$Script:AppState.Controls['btnExportCsv'].Add_Click({
  try {
    if ($Script:AppState.TargetRows.Count -eq 0) {
      Enqueue-UiLog "No status data to export." "WARN"
      return
    }

    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title = 'Export Device Status'
    $dlg.Filter = 'CSV|*.csv'
    $dlg.FileName = "DeviceStatus_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
      $Script:AppState.TargetRows | Select-Object Device, State, LastMessage | Export-Csv -LiteralPath $dlg.FileName -NoTypeInformation -Encoding UTF8
      Enqueue-UiLog "Exported device status to $($dlg.FileName)." "SUCCESS"
    }
  } catch {
    Enqueue-UiLog ("Export failed: " + $_.Exception.Message) "ERROR"
  }
})
#endregion

# Alt Cred Toggle
#region ======================== ALT CRED TOGGLE ============================
$Script:AppState.Controls['chkAltCred'].Add_Click({
  try {
    if ($Script:AppState.IsRunning) { Enqueue-UiLog "Cannot change credentials while running." "WARN"; $Script:AppState.Controls['chkAltCred'].IsChecked = $true; return }

    if ($Script:AppState.Controls['chkAltCred'].IsChecked) {
      $c = Show-CredentialDialog -Title 'Alternate Credentials' -Hint 'Enter credentials for remote execution.'
      if (-not $c) {
        $Script:AppState.Controls['chkAltCred'].IsChecked = $false
        $Script:AppState.AltCredential = $null
        Set-AltCredStatus -Cred $null
        Enqueue-UiLog "Alt Cred cancelled." "WARN"
        return
      }
      $Script:AppState.AltCredential = $c
      Set-AltCredStatus -Cred $c
      Enqueue-UiLog ("Alt Cred set: " + $c.UserName) "SUCCESS"
    }
    else {
      $Script:AppState.AltCredential = $null
      Set-AltCredStatus -Cred $null
      Enqueue-UiLog "Alt Cred cleared." "INFO"
    }
  }
  catch { Enqueue-UiLog ("Alt Cred error: " + $_.Exception.Message) "ERROR" }
})
#endregion

# Queue & Concurrency
#region ======================== QUEUE & CONCURRENCY ============================
function Get-MaxConcurrentFromUi {
  $v = 8
  try { $v = [int]$Script:AppState.Controls['txtMaxConcurrent'].Text } catch { $v = 8 }
  if ($v -lt 1) { $v = 1 }
  if ($v -gt 32) { $v = 32 }
  $Script:AppState.Controls['txtMaxConcurrent'].Text = [string]$v
  return $v
}

# Start next queued tasks
function Start-NextQueuedTasks {
  param(
    [string]$Custom,
    [bool]$DoPing,
    [bool]$DoWsman,
    [bool]$UseCred,
    [pscredential]$Cred,
    [int]$TimeoutSec = 120
  )

  if ($Script:AppState.CancelRequested) { return }

  while (($Script:AppState.Jobs.Count -lt $Script:AppState.MaxConcurrent) -and ($Script:AppState.Queue.Count -gt 0)) {
    $dev = $Script:AppState.Queue.Dequeue()

    if ($Script:AppState.CancelRequested) {
      Update-DeviceRow -RowMap $Script:AppState.RowMap -Device $dev -State 'Cancelled' -LastMessage 'Cancelled before start.'
      continue
    }

    Update-DeviceRow -RowMap $Script:AppState.RowMap -Device $dev -State 'Running' -LastMessage 'Starting...'

    $started = Start-RemoteTask -Computer $dev -CustomText $Custom `
      -DoPing $DoPing -DoWsman $DoWsman -UseCred $UseCred -Cred $Cred -TimeoutSec $TimeoutSec

    if (-not $started) {
      Update-DeviceRow -RowMap $Script:AppState.RowMap -Device $dev -State 'Failed' -LastMessage 'Failed to initialize session.'
    }
  }
}
#endregion

# Run Finalizer
#region ======================== RUN FINALIZER ============================
function Complete-Run {
  param(
    [string]$RuntimeText,
    [string]$LogMessage,
    [string]$LogLevel = 'SUCCESS'
  )

  $Script:AppState.UiTimer.Stop()

  $Script:AppState.IsRunning = $false
  Refresh-InputMode

  Set-Progress -Value $Script:AppState.DoneCount -Max ([Math]::Max(1, $Script:AppState.TotalTargets))
  $Script:AppState.Controls['txtRuntime'].Text = $RuntimeText
  Enqueue-UiLog $LogMessage $LogLevel
}
#endregion

# Job Poller
#region ======================== JOB POLLER ============================
$Script:AppState.UiTimer.Add_Tick({
  try {
    # Recalculate DoneCount directly from state to guarantee sync
    $Script:AppState.DoneCount = @($Script:AppState.TargetRows | Where-Object { $_.State -in @('Success', 'Failed', 'Cancelled') }).Count
    Set-Progress -Value $Script:AppState.DoneCount -Max $Script:AppState.TotalTargets

    $noWork = ($Script:AppState.Jobs.Count -eq 0 -and $Script:AppState.Queue.Count -eq 0)
    if ($noWork -and ($Script:AppState.TotalTargets -gt 0) -and ($Script:AppState.DoneCount -ge $Script:AppState.TotalTargets)) {
      $stateText = if ($Script:AppState.CancelRequested) { 'Cancelled' } else { 'Completed' }
      $logMsg    = if ($Script:AppState.CancelRequested) { 'Run cancelled by user.' } else { 'All tasks completed.' }
      $logLevel  = if ($Script:AppState.CancelRequested) { 'WARN' } else { 'SUCCESS' }
      Complete-Run -RuntimeText $stateText -LogMessage $logMsg -LogLevel $logLevel
      return
    }
    if ($noWork) { return }

    $done = New-Object System.Collections.ArrayList

    foreach ($j in @($Script:AppState.Jobs)) {
      if (-not $j.Async) { continue }

      $isComp = $false
      try { $isComp = $j.Async.IsCompleted } catch { $isComp = $true }

      # 2-Minute Force Timeout
      if (-not $isComp -and (($j.Started).AddMinutes(2) -lt (Get-Date))) {
        try { $j.PS.BeginStop($null, $null) } catch {}
        Update-DeviceRow -RowMap $Script:AppState.RowMap -Device $j.Computer -State 'Failed' -LastMessage 'Timeout after 2 minutes.'
        Enqueue-UiLog "Timeout after 2 minutes." "ERROR" $j.Computer
        Enqueue-UiLog "==================================================" "DIVIDER"
        [void]$done.Add($j)
        continue
      }

      if ($isComp) {
        $json = $null
        try {
          $res = $j.PS.EndInvoke($j.Async)
          $json = ($res | Out-String).Trim()
        } catch { $json = $null }

        try { $j.PS.BeginStop($null, $null) } catch {}
        [void]$done.Add($j)

        if (-not $json) {
          Update-DeviceRow -RowMap $Script:AppState.RowMap -Device $j.Computer -State 'Failed' -LastMessage 'No response from worker.'
          Enqueue-UiLog "No response from worker." "ERROR" $j.Computer
          Enqueue-UiLog "==================================================" "DIVIDER"
          $Script:AppState.LastResults += [pscustomobject]@{ Device=$j.Computer; State='Failed'; Message='No response.'}
        }
        else {
          $obj = $null
          try { $obj = $json | ConvertFrom-Json } catch { $obj = $null }

          if ($obj) {
            $outFile = ''
            if ($obj.State -eq 'Success') {
              Enqueue-UiLog $obj.Message "SUCCESS" $obj.Computer

              if ($obj.Output) {
                if ([bool]$Script:AppState.Controls['chkSaveOutput'].IsChecked) {
                  $safe = ($obj.Computer -replace '[\\/:*?"<>| ]','_')
                  $outFile = Join-Path $Script:AppState.Paths.Outputs ("{0}_{1}.txt" -f $safe, (Get-Date -Format 'yyyyMMdd_HHmmss'))
                  try { Set-Content -LiteralPath $outFile -Value $obj.Output -Encoding UTF8 } catch { $outFile = '' }
                }
                Enqueue-UiLog $obj.Output "INFO" $obj.Computer
              }
            }
            else {
              Enqueue-UiLog $obj.Message "ERROR" $obj.Computer
            }

            Update-DeviceRow -RowMap $Script:AppState.RowMap -Device $obj.Computer -State $obj.State -LastMessage $obj.Message 
            $Script:AppState.LastResults += [pscustomobject]@{ Device=$obj.Computer; State=$obj.State; Message=$obj.Message}
            Enqueue-UiLog "==================================================" "DIVIDER"
          }
          else {
            Update-DeviceRow -RowMap $Script:AppState.RowMap -Device $j.Computer -State 'Failed' -LastMessage 'Invalid JSON result.'
            Enqueue-UiLog "Invalid JSON result." "ERROR" $j.Computer
            $Script:AppState.LastResults += [pscustomobject]@{ Device=$j.Computer; State='Failed'; Message='Invalid JSON result.'}
            Enqueue-UiLog "==================================================" "DIVIDER"
          }
        }
      }
    }

    if ($done.Count -gt 0) { foreach ($d in $done) { [void]$Script:AppState.Jobs.Remove($d) } }

    Start-NextQueuedTasks -Custom $Script:AppState.Controls['txtCustom'].Text `
      -DoPing ([bool]$Script:AppState.Controls['chkPing'].IsChecked) -DoWsman ([bool]$Script:AppState.Controls['chkWsman'].IsChecked) `
      -UseCred ([bool]$Script:AppState.Controls['chkAltCred'].IsChecked) -Cred $Script:AppState.AltCredential `
      -TimeoutSec ([int]$Script:AppState.Controls['txtTimeout'].Text)
  }
  catch { Enqueue-UiLog ("Polling error: " + $_.Exception.Message) "ERROR" }
})
#endregion

# Run & Cancel
#region ======================== RUN & CANCEL ============================
function Reset-RunState {
  $Script:AppState.CancelRequested = $false
  $Script:AppState.TargetRows.Clear()
  $Script:AppState.RowMap = @{}

  try { $Script:AppState.Jobs.Clear() | Out-Null } catch {}
  try { $Script:AppState.Queue.Clear() } catch {}

  $Script:AppState.LastResults = @()
  $Script:AppState.TotalTargets = 0
  $Script:AppState.DoneCount = 0
  Set-Progress -Value 0 -Max 1
}

$Script:AppState.Controls['btnRun'].Add_Click({
  try {
    if ($Script:AppState.IsRunning) {
      Enqueue-UiLog "A run is already in progress. Wait until completion or click Cancel." "WARN"
      return
    }

    $targets = Get-SelectedTargets
    if (-not $targets -or $targets.Count -eq 0) { Enqueue-UiLog "No checked targets provided." "WARN"; return }

    $custom = $Script:AppState.Controls['txtCustom'].Text

    if ([string]::IsNullOrWhiteSpace($custom)) {
      Enqueue-UiLog "Provide a Custom Command in the text box." "WARN"
      return
    }

    $Script:AppState.MaxConcurrent = Get-MaxConcurrentFromUi
    
    $timeout = 120
    try { $timeout = [int]$Script:AppState.Controls['txtTimeout'].Text } catch { $timeout = 120 }
    if ($timeout -lt 10) { $timeout = 10 }
    $Script:AppState.Controls['txtTimeout'].Text = [string]$timeout

    Reset-RunState

    $doPing  = [bool]$Script:AppState.Controls['chkPing'].IsChecked
    $doWsman = [bool]$Script:AppState.Controls['chkWsman'].IsChecked
    $useCred = [bool]$Script:AppState.Controls['chkAltCred'].IsChecked
    $cred    = if ($useCred) { $Script:AppState.AltCredential } else { $null }
    if ($useCred -and -not $cred) {
      Enqueue-UiLog "Alt Cred selected but no credentials are set. Click Alt Cred and provide username/password first." "WARN"
      $Script:AppState.Controls['chkAltCred'].IsChecked = $false
      Set-AltCredStatus -Cred $null
      return
    }

    $Script:AppState.TotalTargets = $targets.Count

    $idx = 1
    foreach ($t in $targets) {
      $row = New-DeviceRow -Index $idx -Device $t
      $Script:AppState.TargetRows.Add($row)
      $Script:AppState.RowMap[$t] = $row
      $idx++
    }
    $Script:AppState.Controls['dgStatus'].Items.Refresh()

    foreach ($dev in $targets) { $Script:AppState.Queue.Enqueue($dev) }

    $Script:AppState.IsRunning = $true
    Refresh-InputMode

    $Script:AppState.Controls['txtRuntime'].Text = 'Running'
    Set-Progress -Value 0 -Max $Script:AppState.TotalTargets

    $altUser = if ($useCred -and $cred) { $cred.UserName } else { 'Current user' }
    Enqueue-UiLog ("Run started. Targets={0}, Ping={1}, WSMan={2}, AltCred={3}, AltUser={4}, MaxConcurrent={5}, Timeout={6}s, SaveOutput={7}" -f `
      $targets.Count, $doPing, $doWsman, $useCred, $altUser, $Script:AppState.MaxConcurrent, $timeout, ([bool]$Script:AppState.Controls['chkSaveOutput'].IsChecked)) "INFO"
    Enqueue-UiLog "==================================================" "DIVIDER"

    Start-NextQueuedTasks -Custom $custom -DoPing $doPing -DoWsman $doWsman -UseCred $useCred -Cred $cred -TimeoutSec $timeout
    $Script:AppState.UiTimer.Start()
  }
  catch {
    Enqueue-UiLog ("Run error: " + $_.Exception.Message) "ERROR"
    $Script:AppState.IsRunning = $false
    Refresh-InputMode
    $Script:AppState.Controls['txtRuntime'].Text = 'Idle'
  }
})

$Script:AppState.Controls['btnCancel'].IsEnabled = $false
$Script:AppState.Controls['btnCancel'].Add_Click({
  try {
    if (-not $Script:AppState.IsRunning) { return }

    $Script:AppState.CancelRequested = $true
    Enqueue-UiLog "Cancelling... stopping new tasks and attempting to stop running pipelines." "WARN"

    try { $Script:AppState.Queue.Clear() } catch {}

    foreach ($r in $Script:AppState.TargetRows) {
      if ($r.State -eq 'Queued') {
        $r.State = 'Cancelled'
        $r.LastMessage = 'Cancelled by user.'
      }
    }
    
    if ($Script:AppState.Controls['dgStatus']) { $Script:AppState.Controls['dgStatus'].Items.Refresh() }

    foreach ($j in @($Script:AppState.Jobs)) {
      try { $j.PS.BeginStop($null, $null) } catch {}
    }

    $Script:AppState.IsRunning = $false
    Refresh-InputMode

    $Script:AppState.Controls['txtRuntime'].Text = 'Cancelling'
  }
  catch { Enqueue-UiLog ("Cancel error: " + $_.Exception.Message) "ERROR" }
})
#endregion

# Output Buttons
#region ======================== OUTPUT BUTTONS ============================
$Script:AppState.Controls['btnClearOutput'].Add_Click({ try { $Script:AppState.Controls['rtb'].Document.Blocks.Clear() } catch {} })

$Script:AppState.Controls['btnCopyOutput'].Add_Click({
  try {
    $rtb = $Script:AppState.Controls['rtb']
    $range = New-Object Windows.Documents.TextRange($rtb.Document.ContentStart, $rtb.Document.ContentEnd)
    [System.Windows.Clipboard]::SetText($range.Text)
    Enqueue-UiLog "Output copied to clipboard." "SUCCESS"
  }
  catch { Enqueue-UiLog ("Copy failed: " + $_.Exception.Message) "ERROR" }
})
#endregion

# Window Events & Cleanup
#region ======================== WINDOW EVENTS & CLEANUP ============================
$Script:AppState.Window.Add_Loaded({
  Enqueue-UiLog "Ready." "INFO"
  $Script:AppState.Controls['txtRuntime'].Text = 'Idle'
  Set-Progress -Value 0 -Max 1
  Refresh-InputMode
  Set-AltCredStatus -Cred $Script:AppState.AltCredential

  try { $Script:AppState.LogFlushTimer.Start() } catch {}
})

$Script:AppState.Window.Add_Closing({
  try {
    $Script:AppState.CancelRequested = $true
    try { $Script:AppState.UiTimer.Stop() } catch {}
    try { $Script:AppState.LogFlushTimer.Stop() } catch {}

    foreach ($j in @($Script:AppState.Jobs)) { try { $j.PS.BeginStop($null, $null) } catch {} }
    try { $Script:AppState.Pool.Close() } catch {}
  } catch {}
})
#endregion

# Run UI
#region ======================== RUN UI ============================
[void]$Script:AppState.Window.ShowDialog()
#endregion