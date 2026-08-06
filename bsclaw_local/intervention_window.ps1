param(
    [Parameter(Mandatory=$true)][int]$port,
    [Parameter(Mandatory=$true)][string]$nonce,
    [Parameter(Mandatory=$true)][string]$taskName,
    [Parameter(Mandatory=$true)][string]$resource,
    [Parameter(Mandatory=$true)][string]$reason,
    [Parameter(Mandatory=$true)][ValidateSet('login','verification')][string]$mode,
    [Parameter(Mandatory=$true)][string]$localRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$sent = $false
function Send-Result([string]$action, [hashtable]$values) {
    if ($script:sent) { return }
    $script:sent = $true
    $payload = @{ nonce=$nonce; action=$action; values=$values } | ConvertTo-Json -Compress
    $client = [Net.Sockets.TcpClient]::new('127.0.0.1', $port)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($payload + "`n")
        $stream = $client.GetStream()
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally { $client.Dispose() }
}

$form = [Windows.Forms.Form]::new()
$form.Text = 'BS Claw - Human action'
$form.StartPosition = 'CenterScreen'
$form.Size = [Drawing.Size]::new(540, 410)
$form.TopMost = $true
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.Add_FormClosed({ Send-Result 'cancel' @{} })

$panel = [Windows.Forms.TableLayoutPanel]::new()
$panel.Dock = 'Fill'; $panel.Padding = [Windows.Forms.Padding]::new(18)
$panel.ColumnCount = 1; $panel.RowCount = 9
$form.Controls.Add($panel)
function Add-Label([string]$text, [int]$height=28) {
    $label=[Windows.Forms.Label]::new(); $label.Text=$text; $label.AutoSize=$true; $label.Height=$height; $panel.Controls.Add($label)
}
Add-Label $taskName 34
Add-Label ("Resource: " + $resource)
Add-Label ("Waiting reason: " + $reason) 42
$tenant=$null; $account=$null; $password=$null; $agreement=$null
if ($mode -eq 'login') {
    Add-Label 'Tenant account'
    $tenant=[Windows.Forms.TextBox]::new(); $tenant.Dock='Top'; $panel.Controls.Add($tenant)
    Add-Label 'Operator account'
    $account=[Windows.Forms.TextBox]::new(); $account.Dock='Top'; $panel.Controls.Add($account)
    Add-Label 'Password (hidden)'
    $password=[Windows.Forms.TextBox]::new(); $password.UseSystemPasswordChar=$true; $password.Dock='Top'; $panel.Controls.Add($password)
    $agreement=[Windows.Forms.CheckBox]::new(); $agreement.Text='I confirm the Huice service agreement'; $agreement.AutoSize=$true; $panel.Controls.Add($agreement)
} else {
    Add-Label 'Complete verification in the same resource page, then select Continue.' 46
}
$buttons=[Windows.Forms.FlowLayoutPanel]::new(); $buttons.Dock='Bottom'; $buttons.FlowDirection='RightToLeft'
$cancel=[Windows.Forms.Button]::new(); $cancel.Text='Cancel'; $cancel.Width=90
$cancel.Add_Click({ Send-Result 'cancel' @{}; $form.Close() })
$continue=[Windows.Forms.Button]::new(); $continue.Text='Continue / Submit'; $continue.Width=110
$continue.Add_Click({
    if ($mode -eq 'login') {
        if ([string]::IsNullOrWhiteSpace($tenant.Text) -or [string]::IsNullOrWhiteSpace($account.Text) -or [string]::IsNullOrWhiteSpace($password.Text) -or -not $agreement.Checked) {
            [Windows.Forms.MessageBox]::Show($form, 'Complete the account fields and confirm the agreement.', 'Input required') | Out-Null
            return
        }
        Send-Result 'submit' @{ tenant=$tenant.Text; account=$account.Text; password=$password.Text }
        $tenant.Clear(); $account.Clear(); $password.Clear()
    } else { Send-Result 'continue' @{} }
    $form.Close()
})
$buttons.Controls.Add($cancel); $buttons.Controls.Add($continue); $panel.Controls.Add($buttons)
$form.Add_Shown({ $form.Activate(); $form.Focus() })
[Windows.Forms.Application]::Run($form)
