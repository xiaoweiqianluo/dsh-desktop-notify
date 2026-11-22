#requires -Version 5.1
# DeepSeek Harness notification card.
#
# Draws a small always-on-top card in the bottom-right corner of the primary
# screen, like a chat message popup. It never takes focus. Clicking it brings
# the Harness window back; otherwise it closes itself after a timeout.
#
# This file is ASCII-only on purpose: Windows PowerShell 5.1 reads .ps1 files
# with the ANSI code page unless they carry a BOM, so every localized string
# arrives through environment variables instead:
#
#   DSH_CARD_TITLE     heading text                     (required)
#   DSH_CARD_BODY      body text, wrapped, max 4 lines   (optional)
#   DSH_CARD_FOOTER    small footer text                 (optional)
#   DSH_CARD_KIND      done | wait | error | muted       (accent color)
#   DSH_CARD_DURATION  visible milliseconds before close
#   DSH_CARD_TARGET    process name that "refocuses" on click
#   DSH_CARD_SILENT    '1' suppresses the system sound
#   DSH_CARD_LOG       append diagnostics to this file
#   DSH_CARD_PREVIEW   render one PNG of the card here and exit (design check)
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$logPath = $env:DSH_CARD_LOG
$previewPath = $env:DSH_CARD_PREVIEW

# Every invocation leaves a trail, so "the card never appeared" can be told
# apart from "the card was suppressed because the window was in front".
if (-not $logPath) {
  $logPath = Join-Path $env:TEMP 'dsh-desktop-notify.log'
}

function Write-CardLog([string]$message) {
  if (-not $logPath) { return }
  try {
    # Keep the trail bounded: a long-running installation must not grow it forever.
    if ((Test-Path $logPath) -and ((Get-Item $logPath).Length -gt 200000)) {
      Remove-Item $logPath -Force -ErrorAction SilentlyContinue
    }
    $stamp = (Get-Date).ToString('s')
    Add-Content -Path $logPath -Value "[$stamp] $message" -Encoding UTF8
  } catch { }
}

Write-CardLog "invoked kind=$($env:DSH_CARD_KIND) target=$($env:DSH_CARD_TARGET) hostPid=$($env:DSH_CARD_HOST_PID)"

try {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
} catch {
  Write-CardLog "load WinForms failed: $($_.Exception.Message)"
  exit 1
}

$title = $env:DSH_CARD_TITLE
$body = $env:DSH_CARD_BODY
$footer = $env:DSH_CARD_FOOTER
$kind = $env:DSH_CARD_KIND
if (-not $title) { $title = 'DeepSeek Harness' }
if (-not $body) { $body = '' }
if (-not $footer) { $footer = '' }

$durationMs = 8000
if ($env:DSH_CARD_DURATION) {
  $parsed = 0
  if ([int]::TryParse($env:DSH_CARD_DURATION, [ref]$parsed) -and $parsed -ge 1500) { $durationMs = $parsed }
}

$targetProcess = $env:DSH_CARD_TARGET
if (-not $targetProcess) { $targetProcess = 'DeepSeek Harness' }

$windowTitle = 'DSHNotifierCard'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class DshCardNative {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern IntPtr FindWindow(string className, string windowName);
  [DllImport("user32.dll")]
  public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")]
  public static extern bool ShowWindow(IntPtr hWnd, int cmd);
  [DllImport("user32.dll")]
  public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")]
  public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
  [DllImport("kernel32.dll")]
  public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")]
  public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")]
  public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
  [DllImport("user32.dll")]
  public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")]
  public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint flags);

  public const uint WM_CLOSE = 0x0010;
  public const int SW_RESTORE = 9;
  public const int SW_SHOW = 5;
  public const int SW_SHOWMAXIMIZED = 3;

  public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
  public const uint SWP_NOSIZE = 0x0001;
  public const uint SWP_NOMOVE = 0x0002;
  public const uint SWP_NOACTIVATE = 0x0010;
  public const uint SWP_SHOWWINDOW = 0x0040;

  // Put the card at the very top of the topmost band without activating it.
  // Windows keeps several topmost windows stacked; a window activated later
  // would otherwise sit above the card, which is what makes a popup disappear
  // behind whatever the user just clicked.
  public static bool RaiseToTop(IntPtr hWnd, bool show) {
    uint flags = SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | (show ? SWP_SHOWWINDOW : 0);
    return SetWindowPos(hWnd, HWND_TOPMOST, 0, 0, 0, 0, flags);
  }

  public static void CloseExisting(string title) {
    IntPtr existing = FindWindow(null, title);
    if (existing != IntPtr.Zero) {
      PostMessage(existing, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
      System.Threading.Thread.Sleep(120);
    }
  }

  // True when the foreground window belongs to one of the given process ids
  // or process names, i.e. the user already looks at the Harness.
  public static bool ForegroundIs(int allowedPid, string allowedName) {
    IntPtr handle = GetForegroundWindow();
    if (handle == IntPtr.Zero) return false;
    uint pid = 0;
    GetWindowThreadProcessId(handle, out pid);
    if (pid == 0) return false;
    if (allowedPid > 0 && (int)pid == allowedPid) return true;
    if (String.IsNullOrEmpty(allowedName)) return false;
    try {
      System.Diagnostics.Process process = System.Diagnostics.Process.GetProcessById((int)pid);
      return String.Equals(process.ProcessName, allowedName, StringComparison.OrdinalIgnoreCase);
    } catch { return false; }
  }

  // Diagnostics: what the foreground window belongs to right now.
  public static string DescribeForeground() {
    IntPtr handle = GetForegroundWindow();
    if (handle == IntPtr.Zero) return "pid=0 name=<none>";
    uint pid = 0;
    GetWindowThreadProcessId(handle, out pid);
    string name = "<unknown>";
    try { name = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { }
    return "pid=" + pid + " name=" + name;
  }

  // Diagnostics: the visible windows stacked above this one, nearest first.
  [DllImport("user32.dll")]
  private static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int max);
  [DllImport("user32.dll")]
  private static extern int GetWindowLong(IntPtr hWnd, int index);
  [DllImport("user32.dll")]
  private static extern bool IsWindowVisible(IntPtr hWnd);

  // Diagnostics: this window's own extended style, to prove the topmost bit.
  public static string DescribeStyle(IntPtr hWnd) {
    int style = GetWindowLong(hWnd, -20); // GWL_EXSTYLE
    return "ex=0x" + style.ToString("X")
      + " topmost=" + ((style & 0x00000008) != 0)
      + " toolwindow=" + ((style & 0x00000080) != 0)
      + " noactivate=" + ((style & 0x08000000) != 0);
  }

  public static string AboveUs(IntPtr hWnd) {
    System.Text.StringBuilder result = new System.Text.StringBuilder();
    IntPtr cursor = GetWindow(hWnd, 3); // GW_HWNDPREV
    int seen = 0;
    while (cursor != IntPtr.Zero && seen < 5) {
      if (IsWindowVisible(cursor)) {
        System.Text.StringBuilder title = new System.Text.StringBuilder(160);
        GetWindowText(cursor, title, 160);
        int style = GetWindowLong(cursor, -20); // GWL_EXSTYLE
        bool topmost = (style & 0x00000008) != 0; // WS_EX_TOPMOST
        result.Append("[topmost=" + topmost + " title=" + title + "] ");
        seen++;
      }
      cursor = GetWindow(cursor, 3);
    }
    if (seen == 0) return "<nothing above>";
    return result.ToString();
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct POINT { public int X; public int Y; }
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [StructLayout(LayoutKind.Sequential)]
  public struct WINDOWPLACEMENT {
    public int length;
    public int flags;
    public int showCmd;
    public POINT ptMinPosition;
    public POINT ptMaxPosition;
    public RECT rcNormalPosition;
  }
  [DllImport("user32.dll")]
  public static extern bool GetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT lpwndpl);

  // True when the window was maximized before a possible minimize.
  // WPF_RESTORETOMAXIMIZED covers "maximized then minimized", where showCmd
  // is SW_SHOWMINIMIZED.
  public static bool WasMaximized(IntPtr hWnd) {
    WINDOWPLACEMENT wp = new WINDOWPLACEMENT();
    wp.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
    if (!GetWindowPlacement(hWnd, ref wp)) return false;
    return (wp.flags & 0x0002) != 0 || wp.showCmd == 3;
  }
}

// Calls back on every foreground-window change, so the card can reclaim the
// top of the topmost band the moment something else becomes active instead of
// waiting for the next poll tick.
public static class DshForegroundHook {
  public delegate void WinEventDelegate(IntPtr hook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
  [DllImport("user32.dll")]
  private static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr module, WinEventDelegate callback, uint processId, uint threadId, uint flags);
  [DllImport("user32.dll")]
  private static extern bool UnhookWinEvent(IntPtr hook);

  private const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
  private const uint WINEVENT_OUTOFCONTEXT = 0x0000;
  private const uint WINEVENT_SKIPOWNPROCESS = 0x0002;

  private static WinEventDelegate callback;
  private static IntPtr hook = IntPtr.Zero;

  public static bool Install(Action onForeground) {
    callback = delegate { try { onForeground(); } catch { } };
    hook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, callback, 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    return hook != IntPtr.Zero;
  }

  public static void Uninstall() {
    if (hook != IntPtr.Zero) {
      UnhookWinEvent(hook);
      hook = IntPtr.Zero;
    }
    callback = null;
  }
}

// Never steals focus, never appears in Alt+Tab, stays above other windows.
public class DshCardForm : Form {
  public DshCardForm() {
    SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
    UpdateStyles();
  }
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override CreateParams CreateParams {
    get {
      CreateParams cp = base.CreateParams;
      // WS_EX_TOPMOST must be present at creation: asking the window manager
      // later with SetWindowPos(HWND_TOPMOST) can be accepted (TRUE) and still
      // leave the window out of the topmost band, which is how the card ended
      // up behind an ordinary maximized browser window.
      cp.ExStyle |= 0x00000008; // WS_EX_TOPMOST
      cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
      cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
      return cp;
    }
  }
}
'@ -ReferencedAssemblies System.Windows.Forms, System.Drawing

try { [void][DshCardNative]::SetProcessDPIAware() } catch { }

# The user is looking at the Harness: no popup. This also skips the render,
# so a notification that arrives while the window is focused costs ~0.4 s of
# one short-lived PowerShell process and never flashes on screen.
if ($env:DSH_CARD_ALWAYS -ne '1') {
  $hostPid = 0
  if ($env:DSH_CARD_HOST_PID) { [void][int]::TryParse($env:DSH_CARD_HOST_PID, [ref]$hostPid) }
  $foreground = [DshCardNative]::DescribeForeground()
  Write-CardLog "foreground=$foreground hostPid=$hostPid target=$targetProcess"
  if ([DshCardNative]::ForegroundIs($hostPid, $targetProcess)) {
    Write-CardLog 'skipped: harness window is foreground'
    exit 0
  }
}

# Retire an older card before this process creates its own window: FindWindow
# matches by title, so a handle of our own must not exist yet.
[DshCardNative]::CloseExisting($windowTitle)

try {
  $accentByKind = @{
    done  = [System.Drawing.Color]::FromArgb(72, 190, 132)
    wait  = [System.Drawing.Color]::FromArgb(235, 176, 64)
    error = [System.Drawing.Color]::FromArgb(232, 104, 104)
    muted = [System.Drawing.Color]::FromArgb(136, 142, 154)
  }
  $accent = $accentByKind[$kind]
  if ($null -eq $accent) { $accent = $accentByKind.done }

  # Follow the Windows app theme so the card does not glare at night.
  $dark = $true
  try {
    $personalize = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop
    if ($null -ne $personalize.AppsUseLightTheme) { $dark = ($personalize.AppsUseLightTheme -eq 0) }
  } catch { }

  if ($dark) {
    $background = [System.Drawing.Color]::FromArgb(32, 34, 39)
    $borderColor = [System.Drawing.Color]::FromArgb(60, 64, 72)
    $titleInk = [System.Drawing.Color]::FromArgb(244, 245, 247)
    $bodyInk = [System.Drawing.Color]::FromArgb(204, 208, 216)
    $footerInk = [System.Drawing.Color]::FromArgb(140, 146, 157)
    $hintInk = [System.Drawing.Color]::FromArgb(110, 116, 127)
  } else {
    $background = [System.Drawing.Color]::FromArgb(253, 253, 254)
    $borderColor = [System.Drawing.Color]::FromArgb(224, 227, 232)
    $titleInk = [System.Drawing.Color]::FromArgb(26, 28, 32)
    $bodyInk = [System.Drawing.Color]::FromArgb(72, 78, 88)
    $footerInk = [System.Drawing.Color]::FromArgb(122, 128, 138)
    $hintInk = [System.Drawing.Color]::FromArgb(150, 156, 166)
  }

  $probe = New-Object System.Drawing.Bitmap 1, 1
  $probeGraphics = [System.Drawing.Graphics]::FromImage($probe)
  $scale = $probeGraphics.DpiX / 96
  $probeGraphics.Dispose()
  $probe.Dispose()
  if ($scale -lt 0.75) { $scale = 0.75 }
  if ($scale -gt 3) { $scale = 3 }

  $width = [int][Math]::Round(396 * $scale)
  $padding = [int][Math]::Round(15 * $scale)
  $accentWidth = [int][Math]::Round(4 * $scale)
  $textLeft = $padding + $accentWidth + [int][Math]::Round(10 * $scale)
  $textWidth = $width - $textLeft - $padding
  $radius = [int][Math]::Round(10 * $scale)

  # Close button in the top-right corner: a comfortable hit square with the
  # glyph drawn inside it. The title loses that width so it never runs under it.
  $closeSize = [int][Math]::Round(22 * $scale)
  $closeLeft = $width - $padding - $closeSize
  $closeTop = $padding - [int][Math]::Round(2 * $scale)
  $titleWidth = $textWidth - $closeSize - [int][Math]::Round(8 * $scale)
  if ($titleWidth -lt 80) { $titleWidth = 80 }

  $fontFamily = 'Microsoft YaHei UI'
  try {
    $installed = [System.Drawing.FontFamily]::Families | ForEach-Object { $_.Name }
    if ($installed -notcontains $fontFamily) { $fontFamily = 'Segoe UI' }
  } catch { }

  $titlePx = [single][Math]::Round(14.5 * $scale)
  $bodyPx = [single][Math]::Round(13 * $scale)
  $footerPx = [single][Math]::Round(11.5 * $scale)
  $titleFont = New-Object System.Drawing.Font $fontFamily, $titlePx, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
  $bodyFont = New-Object System.Drawing.Font $fontFamily, $bodyPx, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
  $footerFont = New-Object System.Drawing.Font $fontFamily, $footerPx, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)

  $form = New-Object DshCardForm
  $form.Text = $windowTitle
  $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
  $form.ShowInTaskbar = $false
  $form.TopMost = $true
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
  $form.BackColor = $background
  $form.Width = $width
  $form.Height = 140

  $measureGraphics = $form.CreateGraphics()
  $measureGraphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

  $titleFormat = New-Object System.Drawing.StringFormat
  $titleFormat.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
  $titleFormat.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
  $titleSize = $measureGraphics.MeasureString($title, $titleFont, (New-Object System.Drawing.SizeF $titleWidth, 400), $titleFormat)

  $bodySize = New-Object System.Drawing.SizeF 0, 0
  $bodyFormat = New-Object System.Drawing.StringFormat
  if ($body) {
    $bodyFormat.Trimming = [System.Drawing.StringTrimming]::EllipsisWord
    $bodySize = $measureGraphics.MeasureString($body, $bodyFont, (New-Object System.Drawing.SizeF $textWidth, 4000), $bodyFormat)
  }

  $footerSize = New-Object System.Drawing.SizeF 0, 0
  $footerFormat = New-Object System.Drawing.StringFormat
  if ($footer) {
    $footerFormat.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
    $footerFormat.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
    $footerSize = $measureGraphics.MeasureString($footer, $footerFont, (New-Object System.Drawing.SizeF $textWidth, 400), $footerFormat)
  }
  $lineHeight = [int][Math]::Ceiling($bodyFont.GetHeight($measureGraphics))
  $measureGraphics.Dispose()

  $titleHeight = [int][Math]::Ceiling($titleSize.Height)
  $bodyHeight = 0
  if ($body) { $bodyHeight = [int][Math]::Ceiling([Math]::Min($bodySize.Height, $lineHeight * 4)) }
  $footerHeight = 0
  if ($footer) { $footerHeight = [int][Math]::Ceiling($footerSize.Height) }

  $gapTitleBody = [int][Math]::Round(7 * $scale)
  $gapBodyFooter = [int][Math]::Round(9 * $scale)
  $height = $padding + $titleHeight
  if ($body) { $height += $gapTitleBody + $bodyHeight }
  if ($footer) { $height += $gapBodyFooter + $footerHeight }
  $height += $padding

  $titleTop = $padding
  $bodyTop = $titleTop + $titleHeight + $gapTitleBody
  $footerTop = $bodyTop + $bodyHeight + $gapBodyFooter

  $form.Height = $height
  $workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $finalLeft = $workArea.Right - $width - [int][Math]::Round(18 * $scale)
  $finalTop = $workArea.Bottom - $height - [int][Math]::Round(18 * $scale)
  $form.Left = $finalLeft
  $form.Top = $finalTop

  $script:card = @{
    title = $title
    body = $body
    footer = $footer
    width = $width
    height = $height
    padding = $padding
    accentWidth = $accentWidth
    textLeft = $textLeft
    textWidth = $textWidth
    titleWidth = $titleWidth
    closeLeft = $closeLeft
    closeTop = $closeTop
    closeSize = $closeSize
    hoverClose = $false
    radius = $radius
    titleTop = $titleTop
    titleHeight = $titleHeight
    bodyTop = $bodyTop
    bodyHeight = $bodyHeight
    footerTop = $footerTop
    accent = $accent
    background = $background
    border = $borderColor
    titleInk = $titleInk
    bodyInk = $bodyInk
    footerInk = $footerInk
    hintInk = $hintInk
    dark = $dark
    titleFont = $titleFont
    bodyFont = $bodyFont
    footerFont = $footerFont
    titleFormat = $titleFormat
    bodyFormat = $bodyFormat
    footerFormat = $footerFormat
    painted = $false
    ticks = 0
    slide = $false
    slideFrom = $workArea.Right
    slideTo = $finalLeft
    slideStart = 0
  }

  function Get-CardPath([hashtable]$card) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $diameter = $card.radius * 2
    $arc = New-Object System.Drawing.Rectangle 0, 0, $diameter, $diameter
    $path.AddArc($arc, 180, 90)
    $arc.X = $card.width - $diameter - 1
    $path.AddArc($arc, 270, 90)
    $arc.Y = $card.height - $diameter - 1
    $path.AddArc($arc, 0, 90)
    $arc.X = 0
    $path.AddArc($arc, 90, 90)
    $path.CloseFigure()
    return $path
  }

  $script:renderCard = {
    param([System.Drawing.Graphics]$graphics)
    $card = $script:card
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $graphics.Clear($card.background)

    $path = Get-CardPath $card
    $fill = New-Object System.Drawing.SolidBrush $card.background
    $graphics.FillPath($fill, $path)
    $borderPen = New-Object System.Drawing.Pen $card.border, 1
    $graphics.DrawPath($borderPen, $path)

    $accentBrush = New-Object System.Drawing.SolidBrush $card.accent
    $accentTop = $card.titleTop + [int][Math]::Round(2 * $scale)
    $accentHeight = [Math]::Max([int][Math]::Round(18 * $scale), $card.titleHeight - [int][Math]::Round(4 * $scale))
    $graphics.FillRectangle($accentBrush, $card.padding, $accentTop, $card.accentWidth, $accentHeight)

    $titleBrush = New-Object System.Drawing.SolidBrush $card.titleInk
    $graphics.DrawString($card.title, $card.titleFont, $titleBrush, (New-Object System.Drawing.RectangleF $card.textLeft, $card.titleTop, $card.titleWidth, ($card.titleHeight + 2)), $card.titleFormat)

    # Close button: a filled circle on hover, then two strokes for the cross.
    if ($card.hoverClose) {
      $hoverColor = if ($card.dark) {
        [System.Drawing.Color]::FromArgb(40, 255, 255, 255)
      } else {
        [System.Drawing.Color]::FromArgb(26, 0, 0, 0)
      }
      $hoverBrush = New-Object System.Drawing.SolidBrush $hoverColor
      $graphics.FillEllipse($hoverBrush, $card.closeLeft, $card.closeTop, $card.closeSize, $card.closeSize)
      $hoverBrush.Dispose()
    }
    $crossColor = if ($card.hoverClose) { $card.titleInk } else { $card.footerInk }
    $crossPen = New-Object System.Drawing.Pen $crossColor, ([single][Math]::Max(1.3, 1.4 * $scale))
    $crossPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $crossPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $crossInset = [int][Math]::Round($card.closeSize * 0.32)
    $x1 = $card.closeLeft + $crossInset
    $y1 = $card.closeTop + $crossInset
    $x2 = $card.closeLeft + $card.closeSize - $crossInset
    $y2 = $card.closeTop + $card.closeSize - $crossInset
    $graphics.DrawLine($crossPen, $x1, $y1, $x2, $y2)
    $graphics.DrawLine($crossPen, $x2, $y1, $x1, $y2)
    $crossPen.Dispose()

    if ($card.body) {
      $bodyBrush = New-Object System.Drawing.SolidBrush $card.bodyInk
      $graphics.DrawString($card.body, $card.bodyFont, $bodyBrush, (New-Object System.Drawing.RectangleF $card.textLeft, $card.bodyTop, $card.textWidth, $card.bodyHeight), $card.bodyFormat)
      $bodyBrush.Dispose()
    }

    if ($card.footer) {
      $footerBrush = New-Object System.Drawing.SolidBrush $card.footerInk
      $graphics.DrawString($card.footer, $card.footerFont, $footerBrush, (New-Object System.Drawing.RectangleF $card.textLeft, $card.footerTop, $card.textWidth, ($card.footerTop + 40)), $card.footerFormat)
      $footerBrush.Dispose()
    }

    $fill.Dispose(); $borderPen.Dispose(); $accentBrush.Dispose(); $titleBrush.Dispose(); $path.Dispose()
  }

  $form.Add_Paint({
    param($sender, $eventArgs)
    try {
      & $script:renderCard $eventArgs.Graphics
      if (-not $script:card.painted) {
        $script:card.painted = $true
        Write-CardLog 'painted'
      }
    } catch {
      Write-CardLog "paint failed: $($_.Exception.Message)"
    }
  })

  $region = New-Object System.Drawing.Region (Get-CardPath $script:card)
  $form.Region = $region

  # Keep the card on top for its whole life: raising it once at show time is
  # not enough, because any topmost window the user activates afterwards moves
  # above it. Re-asserting costs a SetWindowPos call and never steals focus.
  if (-not $previewPath) {
    $form.Add_Shown({
      try {
        $ok = [DshCardNative]::RaiseToTop($form.Handle, $true)
        Write-CardLog ("raised to top ok=" + $ok + " style=" + [DshCardNative]::DescribeStyle($form.Handle))
      } catch {
        Write-CardLog "raise failed: $($_.Exception.Message)"
      }
    })
    $topmostTimer = New-Object System.Windows.Forms.Timer
    $topmostTimer.Interval = 500
    $topmostTimer.Add_Tick({
      try {
        if (-not [DshCardNative]::RaiseToTop($form.Handle, $false)) {
          if (-not $script:card.raiseFailed) {
            $script:card.raiseFailed = $true
            Write-CardLog 'raise denied by the window manager; retrying on the next tick'
          }
        }
        $script:card.ticks = [int]$script:card.ticks + 1
        if ($script:card.ticks -eq 2) {
          $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
          Write-CardLog ("bounds=" + $form.Bounds + " visible=" + $form.Visible + " wa=" + $wa + " above us: " + [DshCardNative]::AboveUs($form.Handle))
        }
      } catch { }
    })
    $topmostTimer.Start()

    # Reclaim the top immediately on every foreground change (the poll above is
    # only a backstop), so another always-on-top window cannot hide the card.
    try {
      $script:card.onForeground = [Action]{
        if ($script:closed) { return }
        try { [void][DshCardNative]::RaiseToTop($form.Handle, $false) } catch { }
      }
      $hookOk = [DshForegroundHook]::Install($script:card.onForeground)
      Write-CardLog "foreground hook installed=$hookOk"
    } catch {
      Write-CardLog "foreground hook failed: $($_.Exception.Message)"
    }
    $form.Add_FormClosed({
      try { [DshForegroundHook]::Uninstall() } catch { }
    })

    # Slide in from just past the right edge of the working area. The move is a
    # cheap Left interpolation with an ease-out curve; nothing else is animated,
    # so the card stays responsive and never flickers. Set DSH_CARD_ANIMATE=0
    # (plugin config `animate: false`) to make it appear in place instead.
    if ($env:DSH_CARD_ANIMATE -ne '0') {
      $script:card.slide = $true
      $slideTimer = New-Object System.Windows.Forms.Timer
      $slideTimer.Interval = 15
      $slideTimer.Add_Tick({
        $elapsed = [Environment]::TickCount - $script:card.slideStart
        $progress = [Math]::Min(1.0, $elapsed / 220.0)
        $eased = 1.0 - [Math]::Pow(1.0 - $progress, 3)
        $form.Left = [int]($script:card.slideFrom + ($script:card.slideTo - $script:card.slideFrom) * $eased)
        if ($progress -ge 1.0) {
          $slideTimer.Stop()
          $form.Left = $script:card.slideTo
          Write-CardLog 'slide finished'
        }
      })
      $form.Add_Shown({
        $script:card.slideStart = [Environment]::TickCount
        $slideTimer.Start()
      })
    }
  }

  # Preview mode: draw the card into a PNG and exit, so the layout can be
  # reviewed without showing anything on screen.
  if ($previewPath) {
    $form.Add_Shown({
      try {
        $bitmap = New-Object System.Drawing.Bitmap $script:card.width, $script:card.height
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        & $script:renderCard $graphics
        $bitmap.Save($previewPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose(); $bitmap.Dispose()
        Write-CardLog "preview saved to $previewPath"
      } catch {
        Write-CardLog "preview failed: $($_.Exception.Message)"
      }
      $form.Close()
    })
  }

  $script:closed = $false
  $closeCard = {
    if ($script:closed) { return }
    $script:closed = $true
    $form.Close()
  }

  # The close square in the top-right corner: hovering highlights it, clicking
  # it closes the card WITHOUT pulling the Harness forward. Anywhere else keeps
  # the old behaviour (close, then focus the Harness window).
  $isOverClose = {
    param($point)
    $card = $script:card
    return ($point.X -ge $card.closeLeft) -and ($point.X -le ($card.closeLeft + $card.closeSize)) -and
      ($point.Y -ge $card.closeTop) -and ($point.Y -le ($card.closeTop + $card.closeSize))
  }

  $form.Add_MouseMove({
    param($sender, $eventArgs)
    $over = & $isOverClose $eventArgs.Location
    if ($over -ne $script:card.hoverClose) {
      $script:card.hoverClose = $over
      try {
        $form.Cursor = if ($over) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default }
      } catch { }
      $form.Invalidate()
    }
  })

  $form.Add_MouseLeave({
    if ($script:card.hoverClose) {
      $script:card.hoverClose = $false
      try { $form.Cursor = [System.Windows.Forms.Cursors]::Default } catch { }
      $form.Invalidate()
    }
  })

  $form.Add_MouseClick({
    param($sender, $eventArgs)
    if (& $isOverClose $eventArgs.Location) {
      Write-CardLog 'closed by close button'
      & $closeCard
      return
    }
    & $closeCard
    try {
      $hostPid = 0
      if ($env:DSH_CARD_HOST_PID) { [void][int]::TryParse($env:DSH_CARD_HOST_PID, [ref]$hostPid) }
      $target = $null
      if ($hostPid -gt 0) {
        $target = Get-Process -Id $hostPid -ErrorAction SilentlyContinue |
          Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } |
          Select-Object -First 1
      }
      if (-not $target) {
        $target = Get-Process -Name $targetProcess -ErrorAction SilentlyContinue |
          Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } |
          Select-Object -First 1
      }
      if ($target) {
        # Keep the window state: SW_RESTORE also un-maximizes a maximized
        # window, so only call it when the window is minimized.
        $targetHandle = $target.MainWindowHandle
        $wasMaximized = [DshCardNative]::WasMaximized($targetHandle)
        if ([DshCardNative]::IsIconic($targetHandle)) {
          [void][DshCardNative]::ShowWindow($targetHandle, [DshCardNative]::SW_RESTORE)
        }
        if ($wasMaximized) {
          [void][DshCardNative]::ShowWindow($targetHandle, [DshCardNative]::SW_SHOWMAXIMIZED)
        } else {
          [void][DshCardNative]::ShowWindow($targetHandle, [DshCardNative]::SW_SHOW)
        }
        # The Windows foreground lock can reject SetForegroundWindow even though
        # the card just handled a click; attach to the foreground thread and
        # retry when that happens.
        $fgOk = [DshCardNative]::SetForegroundWindow($targetHandle)
        if (-not $fgOk) {
          $fgPid = [uint32]0
          $foreground = [DshCardNative]::GetForegroundWindow()
          $fgThread = [DshCardNative]::GetWindowThreadProcessId($foreground, [ref]$fgPid)
          $myThread = [DshCardNative]::GetCurrentThreadId()
          if ($fgThread -ne 0) {
            [void][DshCardNative]::AttachThreadInput($fgThread, $myThread, $true)
            [void][DshCardNative]::SetForegroundWindow($targetHandle)
            [void][DshCardNative]::AttachThreadInput($fgThread, $myThread, $false)
          }
        }
        Write-CardLog "focus target=$targetHandle maximized=$wasMaximized setfg=$fgOk foregroundAfter=$([DshCardNative]::DescribeForeground())"
      }
    } catch {
      Write-CardLog "focus failed: $($_.Exception.Message)"
    }
  })

  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = $durationMs
  $timer.Add_Tick({ & $closeCard })
  $timer.Start()

  if (-not $previewPath -and $env:DSH_CARD_SILENT -ne '1') {
    try {
      if ($kind -eq 'error') { [System.Media.SystemSounds]::Hand.Play() }
      elseif ($kind -eq 'wait') { [System.Media.SystemSounds]::Exclamation.Play() }
      else { [System.Media.SystemSounds]::Asterisk.Play() }
    } catch { }
  }

  # Replace an older card instead of stacking copies on top of each other.
  Write-CardLog "showing card kind=$kind size=${width}x${height}"
  if (-not $previewPath -and $script:card.slide) {
    $form.Left = $script:card.slideFrom
  }
  [void][System.Windows.Forms.Application]::Run($form)
} catch {
  Write-CardLog "card failed: $($_.Exception.Message)"
  Write-CardLog "stack: $($_.ScriptStackTrace)"
  exit 1
}
