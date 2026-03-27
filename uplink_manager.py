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
#  Uplink Manager                                                       © 2026
#  Author   : Sam Jage
#  Version  : 1.3.3.7
# ──────────────────────────────────────────────────────────────────────────────
#  Purpose  : Configures WinNAT on NAT Uplink per site deployment
#  Platform : Windows 11 Pro
#  Requires : pip install textual
#  Note     : Run as Administrator  (or build exe with uac_admin=True)
#  Date     : March 26, 2026
# ──────────────────────────────────────────────────────────────────────────────
#  Hardcoded  "Internet VLAN"  — WAN uplink            [never modified]
#  Dynamic    "NAT Uplink"     — Reconfigured per site deployment
#                                (gateway IP + subnet)
# ──────────────────────────────────────────────────────────────────────────────

from textual.app import App, ComposeResult
from textual.containers import Container, Horizontal, Vertical
from textual.widgets import Header, Footer, Button, Input, Label, Rule, Log, Switch, Select
from textual.screen import ModalScreen
from textual.binding import Binding
from textual import on, work
import subprocess
import json
import os
import ipaddress
import ctypes
from datetime import datetime
from pathlib import Path

# ── Constants ────────────────────────────────────────────────────────────────
UPLINK_ADAPTER = "NAT Uplink"
WAN_ADAPTER = "Internet VLAN"
APIPA_PREFIX = "169.254."

# Use AppData\Roaming\Uplink Manager for config and logs
APP_DATA = Path(os.getenv('APPDATA')) / "Uplink Manager"
APP_DATA.mkdir(parents=True, exist_ok=True)

CONFIG_FILE = APP_DATA / "nat_builds.json"
SETTINGS_FILE = APP_DATA / "nat_settings.json"
LOGS_DIR = APP_DATA / "logs"
LOGS_DIR.mkdir(exist_ok=True)

# ── Admin check ──────────────────────────────────────────────────────────────


def is_admin() -> bool:
    try:
        return ctypes.windll.shell32.IsUserAnAdmin()
    except Exception:
        return False


# ── Settings persistence ─────────────────────────────────────────────────────
DEFAULT_SETTINGS = {
    "verbose_logs": False,
    "auto_refresh":  True,
    "refresh_secs":  30,
}


def load_settings() -> dict:
    if SETTINGS_FILE.exists():
        with open(SETTINGS_FILE) as f:
            return {**DEFAULT_SETTINGS, **json.load(f)}
    return DEFAULT_SETTINGS.copy()


def save_settings(s: dict):
    with open(SETTINGS_FILE, "w") as f:
        json.dump(s, f, indent=2)

# ── Build config persistence ─────────────────────────────────────────────────


def load_builds() -> dict:
    if CONFIG_FILE.exists():
        with open(CONFIG_FILE) as f:
            return json.load(f)
    return {}


def save_builds(builds: dict):
    with open(CONFIG_FILE, "w") as f:
        json.dump(builds, f, indent=2)

# ── File logger ──────────────────────────────────────────────────────────────


def save_event_log(event_type: str, site: str, lines: list[str]):
    try:
        LOGS_DIR.mkdir(exist_ok=True)
        ts = datetime.now().strftime("%Y-%m-%d-%H-%M")
        safe_site = site.replace(" ", "_").replace("/", "-")
        filename = f"{safe_site}-{event_type}-{ts}.txt"
        log_path = LOGS_DIR / filename
        with open(log_path, "w", encoding="utf-8") as f:
            f.write(f"Uplink Manager — {event_type} Log\n")
            f.write(f"Site    : {site}\n")
            f.write(f"Time    : {ts}\n")
            f.write(
                f"Author  : {os.getenv('USERNAME', os.getenv('USER', 'Unknown'))}\n")
            f.write("─" * 60 + "\n\n")
            for line in lines:
                f.write(line + "\n")
    except Exception:
        pass

# ── PowerShell helper (with hidden window) ───────────────────────────────────


def run_ps(script: str) -> tuple[bool, str]:
    result = subprocess.run(
        ["powershell", "-NoProfile", "-NonInteractive",
            "-ExecutionPolicy", "Bypass", "-Command", script],
        capture_output=True, text=True, creationflags=0x08000000  # CREATE_NO_WINDOW
    )
    out = (result.stdout + result.stderr).strip()
    return result.returncode == 0, out

# ── Status queries ───────────────────────────────────────────────────────────


def get_active_nats() -> list[dict]:
    ok, out = run_ps(
        "Get-NetNat | Select-Object Name, InternalIPInterfaceAddressPrefix | ConvertTo-Json"
    )
    if ok and out:
        try:
            data = json.loads(out)
            return [data] if isinstance(data, dict) else data
        except Exception:
            pass
    return []


def get_uplink_ip() -> str:
    ok, out = run_ps(
        f"Get-NetIPAddress -InterfaceAlias '{UPLINK_ADAPTER}' "
        f"-AddressFamily IPv4 -ErrorAction SilentlyContinue "
        f"| Where-Object {{ $_.PrefixLength -ne 32 }} "
        f"| Select-Object -ExpandProperty IPAddress -First 1"
    )
    ip = out.strip() if ok and out.strip() else ""
    if not ip or ip.startswith(APIPA_PREFIX):
        return ""
    return ip


def get_dns_ips() -> tuple[str, str]:
    """Return (primary, secondary) DNS IPs assigned as /32 on NAT Uplink."""
    ok, out = run_ps(
        f"Get-NetIPAddress -InterfaceAlias '{UPLINK_ADAPTER}' -PrefixLength 32 "
        f"-AddressFamily IPv4 -ErrorAction SilentlyContinue | "
        f"Select-Object -ExpandProperty IPAddress"
    )
    if ok and out:
        ips = [ip.strip() for ip in out.splitlines() if ip.strip()]
        return (ips[0] if len(ips) > 0 else "", ips[1] if len(ips) > 1 else "")
    return "", ""

# ── Validation ────────────────────────────────────────────────────────────────


def validate_ip(ip: str) -> bool:
    try:
        ipaddress.IPv4Address(ip)
        return True
    except ValueError:
        return False


def validate_cidr(cidr: str) -> bool:
    try:
        ipaddress.IPv4Network(cidr, strict=False)
        return True
    except ValueError:
        return False

# ── Prerequisites ────────────────────────────────────────────────────────────


def setup_prerequisites(verbose: bool) -> list[tuple[bool, str]]:
    steps = []

    ok, out = run_ps(
        "Set-ItemProperty "
        "-Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Parameters' "
        "-Name 'IPEnableRouter' -Value 1 -Type DWord -ErrorAction Stop"
    )
    msg = f"[IP Routing Registry] {'OK' if ok else 'FAIL'}"
    if verbose:
        msg += f": {out[:120]}"
    steps.append((ok, msg))

    ok, out = run_ps(
        f"$r = Get-NetFirewallRule -DisplayName 'NAT-Allow-Uplink' -ErrorAction SilentlyContinue; "
        f"if (-not $r) {{ "
        f"New-NetFirewallRule -DisplayName 'NAT-Allow-Uplink' "
        f"-Direction Inbound -Action Allow "
        f"-InterfaceAlias '{UPLINK_ADAPTER}' "
        f"-Protocol Any -ErrorAction Stop }}"
    )
    msg = f"[Firewall Rule] {'OK' if ok else 'FAIL'}"
    if verbose:
        msg += f": {out[:120]}"
    steps.append((ok, msg))

    ok, out = run_ps(
        "Set-Service -Name RemoteAccess -StartupType Automatic -ErrorAction SilentlyContinue; "
        "Start-Service -Name RemoteAccess -ErrorAction SilentlyContinue"
    )
    msg = f"[RemoteAccess Service] {'OK' if ok else 'WARN'}"
    if verbose:
        msg += f": {out[:120]}"
    steps.append((ok, msg))

    return steps

# ── NAT apply ────────────────────────────────────────────────────────────────


def apply_nat(site_name: str, gateway_ip: str, subnet_prefix: str, verbose: bool,
              dns_primary: str = "", dns_secondary: str = "") -> tuple[bool, str]:
    log = []

    try:
        net = ipaddress.IPv4Network(subnet_prefix, strict=False)
        prefix_len = net.prefixlen
        network = str(net.network_address)
    except ValueError as e:
        return False, f"Invalid subnet: {e}"

    log.append("── Prerequisites ──────────────────────")
    any_failed = False
    for ok, msg in setup_prerequisites(verbose):
        log.append(msg)
        if not ok:
            any_failed = True
    log.append("⚠  Some prerequisites failed — NAT may not work correctly." if any_failed
               else "✔  Prerequisites OK.")

    log.append(f"── Configuring {UPLINK_ADAPTER} ────────────")
    ok, out = run_ps(
        f"$a = Get-NetIPAddress -InterfaceAlias '{UPLINK_ADAPTER}' "
        f"-AddressFamily IPv4 -ErrorAction SilentlyContinue; "
        f"if ($a) {{ $a | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue }}"
    )
    msg = f"[Clear existing IPs] {'OK' if ok else 'WARN'}"
    if verbose:
        msg += f": {out[:120]}"
    log.append(msg)

    ok, out = run_ps(
        f"New-NetIPAddress -InterfaceAlias '{UPLINK_ADAPTER}' "
        f"-IPAddress '{gateway_ip}' -PrefixLength {prefix_len} -ErrorAction Stop"
    )
    msg = f"[Set {gateway_ip}/{prefix_len} on '{UPLINK_ADAPTER}'] {'OK' if ok else 'FAIL'}"
    if verbose:
        msg += f": {out[:120]}"
    log.append(msg)
    if not ok:
        return False, "\n".join(log)

    log.append("── WinNAT Rule ────────────────────────")
    run_ps("Get-NetNat | Remove-NetNat -Confirm:$false -ErrorAction SilentlyContinue")
    log.append("[Cleared existing NAT rules]")

    nat_name = f"NAT_{site_name.replace(' ', '_')}"
    ok, out = run_ps(
        f"New-NetNat -Name '{nat_name}' "
        f"-InternalIPInterfaceAddressPrefix '{network}/{prefix_len}' "
        f"-ErrorAction Stop"
    )
    msg = f"[Create NetNat '{nat_name}' → {network}/{prefix_len}] {'OK' if ok else 'FAIL'}"
    if verbose:
        msg += f": {out[:120]}"
    log.append(msg)

    if ok and dns_primary:
        log.append("── DNS Proxy ───────────────────────────")
        dns_ips = [dns_primary]
        if dns_secondary:
            dns_ips.append(dns_secondary)
        for dns_ip in dns_ips:
            ok_dns, out_dns = run_ps(
                f"New-NetIPAddress -InterfaceAlias '{UPLINK_ADAPTER}' "
                f"-IPAddress '{dns_ip}' -PrefixLength 32 "
                f"-ErrorAction SilentlyContinue"
            )
            msg_dns = f"[Add DNS IP {dns_ip}/32 to '{UPLINK_ADAPTER}'] {'OK' if ok_dns else 'WARN'}"
            if verbose:
                msg_dns += f": {out_dns[:120]}"
            log.append(msg_dns)

        forwarders = "'8.8.8.8','8.8.4.4'"
        ok_fwd, out_fwd = run_ps(
            f"Set-DnsClientServerAddress -InterfaceAlias '{WAN_ADAPTER}' "
            f"-ServerAddresses {forwarders} -ErrorAction SilentlyContinue"
        )
        msg_fwd = f"[Set DNS forwarders 8.8.8.8/8.8.4.4 on '{WAN_ADAPTER}'] {'OK' if ok_fwd else 'WARN'}"
        if verbose:
            msg_fwd += f": {out_fwd[:120]}"
        log.append(msg_fwd)

        ok_prx, out_prx = run_ps(
            "netsh routing ip dnsproxy set global enable=yes")
        msg_prx = f"[Enable DNS proxy] {'OK' if ok_prx else 'WARN'}"
        if verbose:
            msg_prx += f": {out_prx[:120]}"
        log.append(msg_prx)

        dns_summary = dns_primary + \
            (f" / {dns_secondary}" if dns_secondary else "")
        log.append(
            f"✔  DNS Proxy active. Devices using {dns_summary} will resolve via 8.8.8.8.")

    if ok:
        log.append(f"\n✔  Site '{site_name}' is live.")
        log.append(
            f"    Gateway: {gateway_ip}  |  Subnet: {network}/{prefix_len}")
        log.append(
            f"    Downstream devices must use {gateway_ip} as their default gateway.")
        if dns_primary:
            log.append(f"    DNS: {dns_primary}" +
                       (f" / {dns_secondary}" if dns_secondary else ""))

    return ok, "\n".join(log)

# ── Teardown ──────────────────────────────────────────────────────────────────


def teardown_nat(verbose: bool) -> tuple[bool, str]:
    log = []
    ok, out = run_ps(
        "Get-NetNat | Remove-NetNat -Confirm:$false -ErrorAction SilentlyContinue")
    msg = f"[Remove NAT rules] {'OK' if ok else 'WARN'}"
    if verbose:
        msg += f": {out[:200]}"
    log.append(msg)

    ok2, out2 = run_ps(
        "Remove-NetFirewallRule -DisplayName 'NAT-Allow-Uplink' -ErrorAction SilentlyContinue"
    )
    msg2 = f"[Remove firewall rule] {'OK' if ok2 else 'WARN'}"
    if verbose:
        msg2 += f": {out2[:120]}"
    log.append(msg2)

    ok3, out3 = run_ps(
        f"Get-NetIPAddress -InterfaceAlias '{UPLINK_ADAPTER}' -PrefixLength 32 "
        f"-AddressFamily IPv4 -ErrorAction SilentlyContinue | "
        f"Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue"
    )
    log.append(
        f"[Clear DNS /32 IPs from '{UPLINK_ADAPTER}'] {'OK' if ok3 else 'WARN'}")

    run_ps("netsh routing ip dnsproxy set global enable=no")
    log.append("[Disable DNS proxy] OK")

    run_ps(
        f"Set-DnsClientServerAddress -InterfaceAlias '{WAN_ADAPTER}' -ResetServerAddresses -ErrorAction SilentlyContinue")
    log.append(f"[Reset DNS forwarders on '{WAN_ADAPTER}'] OK")

    ok4, out4 = run_ps(
        f"Get-NetIPAddress -InterfaceAlias '{UPLINK_ADAPTER}' "
        f"-AddressFamily IPv4 -ErrorAction SilentlyContinue | "
        f"Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue"
    )
    msg4 = f"[Clear all IPs from '{UPLINK_ADAPTER}'] {'OK' if ok4 else 'WARN'}"
    if verbose:
        msg4 += f": {out4[:120]}"
    log.append(msg4)

    return True, "\n".join(log)

# ── Settings Screen ───────────────────────────────────────────────────────────


class SettingsScreen(ModalScreen):
    AUTO_FOCUS = ""
    BINDINGS = [Binding("escape", "dismiss", "Close")]

    def __init__(self, settings: dict, **kwargs):
        super().__init__(**kwargs)
        self._settings = settings.copy()

    def compose(self) -> ComposeResult:
        with Container(id="settings-box"):
            yield Label("⚙  Settings", id="settings-title")

            with Horizontal(classes="setting-row"):
                with Vertical(classes="setting-info"):
                    yield Label("Verbose Logs", classes="setting-label")
                    yield Label("Show full PowerShell output in activity log", classes="setting-desc")
                yield Switch(value=self._settings["verbose_logs"], id="sw-verbose")

            with Horizontal(classes="setting-row"):
                with Vertical(classes="setting-info"):
                    yield Label("Auto Refresh", classes="setting-label")
                    yield Label("Periodically refresh NAT status cards", classes="setting-desc")
                yield Switch(value=self._settings["auto_refresh"], id="sw-autorefresh")

            with Horizontal(classes="setting-row"):
                with Vertical(classes="setting-info"):
                    yield Label("Refresh Interval", classes="setting-label")
                    yield Label("How often to refresh status (seconds)", classes="setting-desc")
                yield Select(
                    [(f"{s}s", s) for s in [15, 30, 60, 120]],
                    value=self._settings["refresh_secs"],
                    id="sel-interval",
                    allow_blank=False,
                )

            with Horizontal(id="settings-buttons"):
                yield Button("Save", id="btn-save")
                yield Button("Close", id="btn-close")

    @on(Switch.Changed, "#sw-verbose")
    def toggle_verbose(self, event: Switch.Changed):
        self._settings["verbose_logs"] = event.value

    @on(Switch.Changed, "#sw-autorefresh")
    def toggle_autorefresh(self, event: Switch.Changed):
        self._settings["auto_refresh"] = event.value

    @on(Select.Changed, "#sel-interval")
    def change_interval(self, event: Select.Changed):
        self._settings["refresh_secs"] = event.value

    @on(Button.Pressed, "#btn-save")
    def save(self):
        save_settings(self._settings)
        self.dismiss(self._settings)

    @on(Button.Pressed, "#btn-close")
    def close(self):
        self.dismiss(None)

# ── Confirm Modal ─────────────────────────────────────────────────────────────


class ConfirmModal(ModalScreen):
    AUTO_FOCUS = ""
    BINDINGS = [Binding("escape", "dismiss(False)", "Cancel")]

    def __init__(self, message: str, **kwargs):
        super().__init__(**kwargs)
        self.message = message

    def compose(self) -> ComposeResult:
        with Container(id="confirm-box"):
            yield Label("⚠  Confirm Action", id="confirm-title")
            yield Rule()
            yield Label(self.message, id="confirm-msg")
            yield Rule()
            with Horizontal(id="confirm-buttons"):
                yield Button("Yes, proceed", id="yes")
                yield Button("Cancel", id="no")

    @on(Button.Pressed, "#yes")
    def confirmed(self):  self.dismiss(True)

    @on(Button.Pressed, "#no")
    def cancelled(self):  self.dismiss(False)

# ── Main App ──────────────────────────────────────────────────────────────────


class UplinkManagerApp(App):

    TITLE = "Uplink Manager"
    SUB_TITLE = "NAT & DNS Proxy Provisioning"
    ENABLE_COMMAND_PALETTE = False
    AUTO_FOCUS = ""

    CSS = """
    Screen { background: #252830; }

    /* Remove focus outlines from all widgets */
    *:focus {
        outline: none !important;
    }

    /* Input gets a yellow border when focused */
    Input:focus {
        border: solid #fabd2f;
    }

    /* Input base styles (unchanged) */
    Input {
        background: $surface;
        border: solid $surface;
        color: $text;
        margin-bottom: 0;
    }
    Input.-invalid { border: solid $error; }

    Header { background: #1a1c24; color: #fabd2f; }
    Footer { background: #1a1c24; color: #a89984; }

    #root {
        layout: horizontal;
        height: 1fr;
        padding: 1 2;
        min-height: 0;
        background: #252830;
    }

    #left-panel {
        width: 52;
        height: 1fr;
        min-height: 0;
        layout: vertical;
        margin-right: 2;
        overflow-y: auto;
        scrollbar-gutter: stable;
        background: #252830;
    }

    #right-panel {
        width: 1fr;
        height: 1fr;
        min-height: 0;
        layout: vertical;
        background: #252830;
    }

    /* Admin warning */
    #admin-warn {
        background: #fb4934 15%;
        border: solid #fb4934;
        color: #fb4934;
        padding: 0 2;
        margin-bottom: 1;
        height: 3;
        display: none;
    }
    #admin-warn.visible { display: block; }

    /* Uplink badge */
    #uplink-badge {
        border: solid #fabd2f;
        background: #2e3038;
        padding: 1 2;
        margin-bottom: 1;
        height: auto;
    }
    #uplink-badge-title {
        color: #a89984;
        text-style: bold;
        margin-bottom: 1;
    }
    #uplink-status {
        color: #fabd2f;
        text-style: bold;
    }
    #uplink-status.configured { color: #26bb3a; text-style: bold; }

    /* Sections */
    .section {
        background: #2e3038;
    }
    .section-form {
        border: solid #404450;
        padding: 1 2 0 2;
        margin-bottom: 1;
    }
    .section-title {
        color: #fabd2f;
        text-style: bold;
        margin-bottom: 1;
    }
    #log-section {
        height: 1fr;
        border: solid #404450;
        background: #2a2d35;
        padding: 1 2;
    }

    /* Form fields */
    .field-desc-line {
        color: #665c54;
        width: 100%;
        height: 1;
    }
    .field-label {
        color: #ebdbb2;
        margin-top: 1;
        margin-bottom: 0;
        text-style: bold;
    }
    .error-text { color: $error; height: 1; }

    /* Buttons */
    #btn-apply {
        margin-top: 0;
        width: 100%;
        background: #3d5c3f;
        color: #ebdbb2;
        border: solid #3d5c3f;
        text-style: bold;
    }
    #btn-apply:hover {
        background: #5a7d5c;
        border: solid #5a7d5c;
    }

    #btn-teardown {
        margin-top: 1;
        width: 100%;
        background: #5a2a2a;
        color: #ebdbb2;
        border: solid #5a2a2a;
        text-style: bold;
    }
    #btn-teardown:hover {
        background: #6e3030;
        border: solid #6e3030;
    }

    /* Spinner styles shared */
    #btn-apply.spinning, #btn-apply.spinning:disabled,
    #btn-teardown.spinning, #btn-teardown.spinning:disabled {
        background: #2e3038;
        border: blank;
        color: #fabd2f;
        text-style: bold;
        opacity: 1;
    }

    /* DNS toggle */
    #dns-toggle-row {
        height: 3;
        margin-top: 0;
        margin-bottom: 0;
        align: left middle;
    }
    #dns-toggle-label { width: auto; margin-right: 2; color: $text-muted; }
    #dns-fields { display: none; margin-bottom: 1; }
    #dns-fields.visible { display: block; margin-bottom: 1; }  /* extra bottom margin for clarity */

        /* Status grid */
    #status-grid {
        layout: grid;
        grid-size: 4;
        grid-gutter: 0;
        height: auto;
        min-height: 9;
        width: 100%;
        margin-bottom: 1;
        background: #252830;
    }
    .stat-box {
        width: 1fr;
        height: 100%;
        border: solid #404450;
        background: #2e3038;
        padding: 1 2;
        margin-right: 1;
    }
    .stat-box:last-of-type { margin-right: 0; }

    #stat-dns-label          { margin-top: 1; color: transparent; }
    #stat-dns-label.visible  { color: $text-muted; text-style: bold; }
    .stat-dns-ip             { color: transparent; text-style: bold; height: 1; }
    .stat-dns-ip.visible     { color: #fabd2f; }

    .stat-label              { color: $text-muted; text-style: bold; }
    .stat-value              { color: $text; margin-top: 1; }
    .stat-value.active       { color: #26bb3a; text-style: bold; }
    .stat-value.inactive     { color: #665c54; }
    .stat-value.warn         { color: #fabd2f; }

    /* Log */
    #log-title { color: #fabd2f; text-style: bold; margin-bottom: 1; }
    Log { background: $surface; color: $text-muted; border: none; height: 1fr; }

    /* Confirm modal */
    ConfirmModal { align: center middle; }
    #confirm-box {
        width: 64; height: auto;
        background: #2e3038; border: solid #fb4934; padding: 1 2;
    }
    #confirm-title { color: #fb4934; text-style: bold; text-align: center; margin-bottom: 1; }
    #confirm-msg   { color: #ebdbb2; text-align: center; margin: 1 0; width: 100%; }
    #confirm-buttons {
        layout: horizontal; align: center middle; margin-top: 1; height: 3;
    }
    #confirm-buttons Button {
        margin: 0 1;
        background: #2e3038;
        color: #ebdbb2;
        border: solid #2e3038;
    }
    #confirm-buttons Button:hover {
        background: #404450;
        border: solid #404450;
        color: #fabd2f;
    }
    #confirm-buttons #yes {
        background: #3d2020;
        color: #fb4934;
        border: solid #3d2020;
    }
    #confirm-buttons #yes:hover {
        background: #5a2020;
        border: solid #5a2020;
    }

    /* Settings modal */
    SettingsScreen { align: center middle; }
    #settings-box {
        width: 62; height: auto;
        background: #2e3038; border: solid #fabd2f; padding: 1 2;
    }
    #settings-title { color: #fabd2f; text-style: bold; text-align: center; margin-bottom: 1; }
    .setting-row    { layout: horizontal; align: left middle; height: 4; margin-bottom: 1; }
    .setting-info   { width: 1fr; layout: vertical; }
    .setting-label  { color: #ebdbb2; text-style: bold; }
    .setting-desc   { color: #a89984; text-style: italic; }
    #settings-buttons {
        layout: horizontal; align: center middle; margin-top: 2; height: 3;
    }
    #settings-buttons Button {
        margin: 0 1;
        background: #2e3038;
        color: #ebdbb2;
        border: solid #2e3038;
    }
    #settings-buttons Button:hover {
        background: #404450;
        border: solid #404450;
        color: #fabd2f;
    }
    #settings-buttons #btn-save {
        background: #3d5c3f;
        color: #ebdbb2;
        border: solid #3d5c3f;
    }
    #settings-buttons #btn-save:hover {
        background: #5a7d5c;
        border: solid #5a7d5c;
    }

    Switch { border: none; background: #252830; padding: 0 1; }
    Switch.-on .switch--slider { color: #fabd2f; }
    Select { width: 20; border: none; background: #252830; color: #ebdbb2; }
    SelectCurrent  { border: solid #404450; background: #252830; color: #ebdbb2; }
    SelectOverlay  { border: solid #404450; background: #252830; color: #ebdbb2; }
    """

    BINDINGS = [
        Binding("ctrl+q", "quit",                 "Quit"),
        Binding("ctrl+r", "action_refresh_status", "Refresh"),
        Binding("ctrl+s", "open_settings",         "Settings"),
    ]

    def __init__(self):
        super().__init__()
        self._settings = load_settings()
        self._refresh_timer = None

    def compose(self) -> ComposeResult:
        yield Header()
        with Container(id="root"):
            with Vertical(id="left-panel"):
                yield Label("⚠  Not running as Administrator — NAT will fail.", id="admin-warn")

                with Container(id="uplink-badge", classes="section"):
                    yield Label("NAT UPLINK", id="uplink-badge-title")
                    yield Label("● Pending Configuration", id="uplink-status")

                with Container(classes="section section-form"):
                    yield Label("Site Configuration", classes="section-title")

                    yield Label("Site Name", classes="field-label")
                    yield Input(placeholder="e.g. Chicago Metro", id="inp-site")
                    yield Label("·  Used for logging and build records only", classes="field-desc-line")

                    yield Label("Site Gateway IP", classes="field-label")
                    yield Input(placeholder="e.g. 10.10.1.1", id="inp-gateway")
                    yield Label("·  Interface IP for downstream devices", classes="field-desc-line")

                    yield Label("Site Subnet (CIDR)", classes="field-label")
                    yield Input(placeholder="e.g. 10.10.1.0/24", id="inp-subnet")
                    yield Label("·  Full address range for this site", classes="field-desc-line")
                    yield Label("·  Gateway IP must fall within this range", classes="field-desc-line")

                    yield Label("", id="val-error", classes="error-text")

                    with Horizontal(id="dns-toggle-row"):
                        yield Label("Enable DNS Proxy", id="dns-toggle-label")
                        yield Switch(value=False, id="sw-dns")
                    with Container(id="dns-fields"):
                        yield Label("DNS Primary", classes="field-label")
                        yield Input(placeholder="e.g. 10.4.100.1", id="inp-dns-primary")
                        yield Label("DNS Secondary", classes="field-label")
                        yield Input(placeholder="Optional", id="inp-dns-secondary")

                    yield Button("⚡  Provision", id="btn-apply")
                    yield Button("🧨  Teardown Uplink", id="btn-teardown")

            with Vertical(id="right-panel"):
                with Container(id="status-grid", classes="section"):
                    with Container(classes="stat-box section", id="stat-box-nat"):
                        yield Label("ACTIVE NAT",  classes="stat-label")
                        yield Label("–", id="stat-nat", classes="stat-value inactive")

                    with Container(classes="stat-box section", id="stat-box-subnet"):
                        yield Label("SITE SUBNET", classes="stat-label")
                        yield Label("–", id="stat-subnet", classes="stat-value inactive")

                    with Container(classes="stat-box section", id="stat-box-uplink"):
                        yield Label("UPLINK IP",   classes="stat-label")
                        yield Label("–", id="stat-uplinkip", classes="stat-value inactive")
                        yield Label("DNS IP",      id="stat-dns-label", classes="stat-label")
                        yield Label("",            id="stat-dns-primary",   classes="stat-dns-ip")
                        yield Label("",            id="stat-dns-secondary", classes="stat-dns-ip")

                    with Container(classes="stat-box section", id="stat-box-time"):
                        yield Label("LAST APPLIED", classes="stat-label")
                        yield Label("–", id="stat-time", classes="stat-value")

                with Container(id="log-section", classes="section"):
                    yield Label("≡  Activity Log", id="log-title")
                    yield Log(id="activity-log", auto_scroll=True)

        yield Footer()

    # ── Lifecycle ─────────────────────────────────────────────────────────────
    def on_mount(self):
        # Disable CSS animations — prevents focus highlight flashes on state changes
        self.animation_level = "none"

        if not is_admin():
            self.query_one("#admin-warn", Label).add_class("visible")
            self._log("⚠  Not running as Administrator. NAT commands will fail.")
        else:
            self._log("✔  Running as Administrator.")

        self._log(
            f"Dynamic adapter: {UPLINK_ADAPTER} — reconfigured per site deployment")
        self._log("Hardcoded: Internet VLAN (WAN uplink) | NAT Uplink (dynamic)")
        self._restore_last_build()
        self.refresh_status()
        self._start_auto_refresh()

        # Force a refresh to ensure footer appears after window resize
        self.set_timer(0.2, self.refresh)

    def _log(self, msg: str):
        ts = datetime.now().strftime("%H:%M:%S")
        self.query_one("#activity-log", Log).write_line(f"[{ts}] {msg}")

    def _restore_last_build(self):
        builds = load_builds()
        if not builds:
            self._log(
                "No previous builds found. Enter site details and hit Provision.")
            return
        site, data = max(
            builds.items(), key=lambda x: x[1].get("last_applied", ""))
        self.query_one("#inp-site", Input).value = site
        self.query_one("#inp-gateway", Input).value = data.get("gateway", "")
        self.query_one("#inp-subnet", Input).value = data.get("subnet", "")

    # ---- Restore DNS settings ----
        dns_primary = data.get("dns_primary", "")
        dns_secondary = data.get("dns_secondary", "")
        if dns_primary:
            self.query_one("#sw-dns", Switch).value = True
            self.query_one("#dns-fields").add_class("visible")
            self.query_one("#inp-dns-primary", Input).value = dns_primary
            self.query_one("#inp-dns-secondary", Input).value = dns_secondary
            self._update_dns_card(dns_primary, dns_secondary)
        else:
            self.query_one("#sw-dns", Switch).value = False
            self.query_one("#dns-fields").remove_class("visible")
            self.query_one("#inp-dns-primary", Input).value = ""
            self.query_one("#inp-dns-secondary", Input).value = ""
            self._update_dns_card("", "")
    # ----------------------------

        self._log(
            f"Restored last build: '{site}' — verify and hit Provision to reapply.")

    def _start_auto_refresh(self):
        if self._refresh_timer:
            self._refresh_timer.stop()
        if self._settings["auto_refresh"]:
            self._refresh_timer = self.set_interval(
                self._settings["refresh_secs"],
                self.refresh_status
            )

    # ── Status refresh ────────────────────────────────────────────────────────
    @work(thread=True)
    def refresh_status(self):
        nats = get_active_nats()
        uplink_ip = get_uplink_ip()
        dns_primary, dns_secondary = get_dns_ips()
        self.call_from_thread(self._update_status_widgets, nats, uplink_ip)
        self.call_from_thread(self._update_dns_card, dns_primary, dns_secondary)

    def _update_status_widgets(self, nats: list[dict], uplink_ip: str):
        nat_lbl = self.query_one("#stat-nat", Label)
        sub_lbl = self.query_one("#stat-subnet", Label)
        upip_lbl = self.query_one("#stat-uplinkip", Label)
        status_lbl = self.query_one("#uplink-status", Label)

        if uplink_ip and nats:
            upip_lbl.update(uplink_ip)
            upip_lbl.set_classes("stat-value active")
            status_lbl.update("● Configured")
            status_lbl.set_classes("configured")
        else:
            upip_lbl.update(uplink_ip if uplink_ip else "– No Valid IP")
            upip_lbl.set_classes("stat-value active" if uplink_ip else "stat-value warn")
            status_lbl.update("● Pending Configuration")
            status_lbl.set_classes("")

        if nats:
            nat_lbl.update(nats[0].get("Name", "–"))
            nat_lbl.set_classes("stat-value active")
            sub_lbl.update(nats[0].get("InternalIPInterfaceAddressPrefix", "–"))
            sub_lbl.set_classes("stat-value active")
        else:
            nat_lbl.update("None")
            nat_lbl.set_classes("stat-value inactive")
            sub_lbl.update("–")
            sub_lbl.set_classes("stat-value inactive")

    def action_refresh_status(self):
        self.refresh_status()
        self._log("Status refreshed manually.")

    def _update_dns_card(self, dns_primary: str, dns_secondary: str):
        label = self.query_one("#stat-dns-label", Label)
        primary = self.query_one("#stat-dns-primary", Label)
        secondary = self.query_one("#stat-dns-secondary", Label)
        if dns_primary:
            label.add_class("visible")
            primary.update(dns_primary)
            primary.add_class("visible")
            if dns_secondary:
                secondary.update(dns_secondary)
                secondary.add_class("visible")
            else:
                secondary.update("")
                secondary.remove_class("visible")
        else:
            label.remove_class("visible")
            primary.update("")
            primary.remove_class("visible")
            secondary.update("")
            secondary.remove_class("visible")

    # ── Button disable helpers ────────────────────────────────────────────────
    def _disable_buttons(self, exclude: str = None):
        """Disable both action buttons, optionally excluding one."""
        if exclude != "provision":
            self.query_one("#btn-apply", Button).disabled = True
        if exclude != "teardown":
            self.query_one("#btn-teardown", Button).disabled = True

    def _enable_buttons(self):
        """Re-enable both action buttons."""
        self.query_one("#btn-apply", Button).disabled = False
        self.query_one("#btn-teardown", Button).disabled = False

    # ── Spinners ──────────────────────────────────────────────────────────────
    def _start_spinner(self, stage: str = ""):
        self._spinner_index = 0
        self._spinner_frames = ["⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷"]
        self._spinner_timer = self.set_interval(0.1, self._tick_spinner)
        self._disable_buttons(exclude="provision")  # disable teardown only
        btn = self.query_one("#btn-apply", Button)
        btn.disabled = True
        btn.add_class("spinning")

    def _stop_spinner(self):
        if hasattr(self, "_spinner_timer"):
            self._spinner_timer.stop()
        self._enable_buttons()
        btn = self.query_one("#btn-apply", Button)
        btn.remove_class("spinning")
        btn.label = "⚡  Provision"
        btn.disabled = False
        btn.refresh()

    def _tick_spinner(self):
        self._spinner_index = (self._spinner_index +
                               1) % len(self._spinner_frames)
        f = self._spinner_frames[self._spinner_index]
        self.query_one("#btn-apply", Button).label = f"  {f}  Provisioning..."

    def _set_spinner_stage(self, stage: str):
        if hasattr(self, "_spinner_frames"):
            f = self._spinner_frames[getattr(self, "_spinner_index", 0)]
            self.query_one("#btn-apply", Button).label = f"  {f}  {stage}"

    def _start_teardown_spinner(self):
        self._td_spinner_index = 0
        self._td_spinner_frames = ["⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷"]
        self._td_spinner_timer = self.set_interval(
            0.1, self._tick_teardown_spinner)
        self._disable_buttons(exclude="teardown")  # disable provision only
        btn = self.query_one("#btn-teardown", Button)
        btn.disabled = True
        btn.add_class("spinning")

    def _stop_teardown_spinner(self):
        if hasattr(self, "_td_spinner_timer"):
            self._td_spinner_timer.stop()
        self._enable_buttons()
        btn = self.query_one("#btn-teardown", Button)
        btn.remove_class("spinning")
        btn.label = "🧨  Teardown Uplink"
        btn.disabled = False
        btn.refresh()

    def _tick_teardown_spinner(self):
        self._td_spinner_index = (
            self._td_spinner_index + 1) % len(self._td_spinner_frames)
        f = self._td_spinner_frames[self._td_spinner_index]
        self.query_one("#btn-teardown",
                       Button).label = f"  {f}  Tearing Down..."

    def _set_teardown_spinner_stage(self, stage: str):
        if hasattr(self, "_td_spinner_frames"):
            f = self._td_spinner_frames[getattr(self, "_td_spinner_index", 0)]
            self.query_one("#btn-teardown", Button).label = f"  {f}  {stage}"

    # ── Settings ──────────────────────────────────────────────────────────────
    def action_open_settings(self):
        def after_settings(new_settings):
            if new_settings:
                self._settings = new_settings
                self._start_auto_refresh()
                self._log("Settings saved.")
        self.push_screen(SettingsScreen(self._settings), after_settings)

    # ── Validation ────────────────────────────────────────────────────────────
    def _validate_form(self) -> str | None:
        site = self.query_one("#inp-site",        Input).value.strip()
        gateway = self.query_one("#inp-gateway",     Input).value.strip()
        subnet = self.query_one("#inp-subnet",      Input).value.strip()
        dns_enabled = self.query_one("#sw-dns",          Switch).value
        dns_primary = self.query_one(
            "#inp-dns-primary", Input).value.strip() if dns_enabled else ""
        dns_secondary = self.query_one(
            "#inp-dns-secondary", Input).value.strip() if dns_enabled else ""
        if not site:
            return "Site name is required."
        if not validate_ip(gateway):
            return f"Invalid gateway IP: {gateway}"
        if not validate_cidr(subnet):
            return f"Invalid subnet CIDR: {subnet}"
        try:
            net = ipaddress.IPv4Network(subnet, strict=False)
            if ipaddress.IPv4Address(gateway) not in net:
                return f"Gateway {gateway} is not within subnet {subnet}"
        except Exception:
            pass
        if dns_enabled and not dns_primary:
            return "DNS Primary IP is required when DNS Proxy is enabled."
        if dns_primary and not validate_ip(dns_primary):
            return f"Invalid DNS Primary IP: {dns_primary}"
        if dns_secondary and not validate_ip(dns_secondary):
            return f"Invalid DNS Secondary IP: {dns_secondary}"
        return None

    # ── Apply ─────────────────────────────────────────────────────────────────
    @on(Button.Pressed, "#btn-apply")
    def on_apply_pressed(self):
        self.query_one("#btn-apply", Button).blur()
        err = self._validate_form()
        err_label = self.query_one("#val-error", Label)
        if err:
            err_label.update(f"⚠ {err}")
            return
        err_label.update("")

        site = self.query_one("#inp-site",           Input).value.strip()
        gateway = self.query_one("#inp-gateway",        Input).value.strip()
        subnet = self.query_one("#inp-subnet",         Input).value.strip()
        dns_enabled = self.query_one("#sw-dns",             Switch).value
        dns_primary = self.query_one(
            "#inp-dns-primary",    Input).value.strip() if dns_enabled else ""
        dns_secondary = self.query_one(
            "#inp-dns-secondary",  Input).value.strip() if dns_enabled else ""

        def after_confirm(confirmed: bool):
            if confirmed:
                self._do_apply(site, gateway, subnet,
                               dns_primary, dns_secondary)

        self.push_screen(
            ConfirmModal(
                f"Apply NAT config for '{site}'?\n\n"
                f"  Uplink:  {UPLINK_ADAPTER}\n"
                f"  Gateway: {gateway}\n"
                f"  Subnet:  {subnet}\n\n"
                f"Downstream devices must use {gateway} as their default gateway."
            ),
            after_confirm,
        )

    @work(thread=True)
    def _do_apply(self, site: str, gateway: str, subnet: str,
                  dns_primary: str = "", dns_secondary: str = ""):
        verbose = self._settings["verbose_logs"]
        self.call_from_thread(self._start_spinner, "Starting...")
        self.call_from_thread(self._log, f"Provisioning site: {site} ...")
        self.call_from_thread(self._set_spinner_stage, "Prerequisites")
        ok, output = apply_nat(site, gateway, subnet,
                               verbose, dns_primary, dns_secondary)

        for line in output.splitlines():
            if line.strip():
                self.call_from_thread(self._log, line)
                if "Configuring" in line:
                    self.call_from_thread(
                        self._set_spinner_stage, "Configuring Interface")
                elif "WinNAT" in line or "NetNat" in line:
                    self.call_from_thread(
                        self._set_spinner_stage, "Creating NAT Rule")
                elif "DNS" in line or "dnsproxy" in line:
                    self.call_from_thread(self._set_spinner_stage, "DNS Proxy")
                elif "Prerequisites" in line:
                    self.call_from_thread(
                        self._set_spinner_stage, "Prerequisites")

        ts = datetime.now().strftime("%H:%M:%S")
        self.call_from_thread(self.query_one("#stat-time", Label).update, ts)
        builds = load_builds()
        builds[site] = {
            "gateway":       gateway,
            "subnet":        subnet,
            "uplink":        UPLINK_ADAPTER,
            "dns_primary":   dns_primary,
            "dns_secondary": dns_secondary,
            "last_applied":  ts,
        }
        save_builds(builds)
        save_event_log("Provision", site, output.splitlines())
        self.call_from_thread(self._stop_spinner)
        self.call_from_thread(self._update_dns_card,
                              dns_primary, dns_secondary)
        self.call_from_thread(self.refresh_status)

    # ── Teardown ──────────────────────────────────────────────────────────────
    @on(Button.Pressed, "#btn-teardown")
    def on_teardown_pressed(self):
        self.query_one("#btn-teardown", Button).blur()

        def after_confirm(confirmed: bool):
            if confirmed:
                self._do_teardown()
        self.push_screen(
            ConfirmModal(
                "Remove ALL NAT rules?\nSite devices will lose internet access."),
            after_confirm,
        )

    @work(thread=True)
    def _do_teardown(self):
        verbose = self._settings["verbose_logs"]
        self.call_from_thread(self._start_teardown_spinner)
        self.call_from_thread(self._log, "Tearing down Uplink...")
        ok, output = teardown_nat(verbose)
        for line in output.splitlines():
            if line.strip():
                self.call_from_thread(self._log, line)
                if "NAT rules" in line or "NetNat" in line:
                    self.call_from_thread(
                        self._set_teardown_spinner_stage, "Removing NAT Rules")
                elif "firewall" in line.lower():
                    self.call_from_thread(
                        self._set_teardown_spinner_stage, "Clearing Firewall")
                elif "DNS" in line or "dnsproxy" in line:
                    self.call_from_thread(
                        self._set_teardown_spinner_stage, "Resetting DNS")
                elif "Clear all IPs" in line or "Clear DNS" in line:
                    self.call_from_thread(
                        self._set_teardown_spinner_stage, "Clearing Interface")
        ts = datetime.now().strftime("%H:%M:%S")
        self.call_from_thread(
            self._log, "✔  Teardown complete. Downstream devices no longer have internet.")
        self.call_from_thread(self.query_one("#stat-time", Label).update, ts)
        builds = load_builds()
        last_site = sorted(builds.items(), key=lambda x: x[1].get(
            "last_applied", ""), reverse=True)
        td_site = last_site[0][0] if last_site else "Unknown"
        save_event_log("Teardown", td_site, output.splitlines())
        self.call_from_thread(self._stop_teardown_spinner)
        self.call_from_thread(self._update_dns_card, "", "")
        self.call_from_thread(self.refresh_status)

    # ── Key handling for numpad decimal ────────────────────────────────────────
    def on_key(self, event):
        if event.key == "decimal":
            if isinstance(self.focused, Input):
                self.focused.insert_text(".")

    # ── Live validation ───────────────────────────────────────────────────────
    @on(Switch.Changed, "#sw-dns")
    def on_dns_toggle(self, event: Switch.Changed):
        dns_fields = self.query_one("#dns-fields")
        if event.value:
            dns_fields.add_class("visible")
        else:
            dns_fields.remove_class("visible")
            self.query_one("#inp-dns-primary",   Input).value = ""
            self.query_one("#inp-dns-secondary", Input).value = ""

    @on(Input.Changed, "#inp-dns-primary")
    def validate_dns_primary_live(self, event: Input.Changed):
        val = event.value.strip()
        event.input.set_class(bool(val and not validate_ip(val)), "-invalid")

    @on(Input.Changed, "#inp-dns-secondary")
    def validate_dns_secondary_live(self, event: Input.Changed):
        val = event.value.strip()
        event.input.set_class(bool(val and not validate_ip(val)), "-invalid")

    @on(Input.Changed, "#inp-gateway")
    def validate_gateway_live(self, event: Input.Changed):
        val = event.value.strip()
        event.input.set_class(bool(val and not validate_ip(val)), "-invalid")

    @on(Input.Changed, "#inp-subnet")
    def validate_subnet_live(self, event: Input.Changed):
        val = event.value.strip()
        event.input.set_class(bool(val and not validate_cidr(val)), "-invalid")


# ── Entry point ───────────────────────────────────────────────────────────────
def enable_vt_mode():
    """Enable virtual terminal processing for 24‑bit color."""
    try:
        kernel32 = ctypes.windll.kernel32
        # Get the console output handle
        handle = kernel32.GetStdHandle(-11)  # STD_OUTPUT_HANDLE
        mode = ctypes.c_ulong()
        kernel32.GetConsoleMode(handle, ctypes.byref(mode))
        # Set the VT flag if not already set
        if not (mode.value & 0x0004):
            kernel32.SetConsoleMode(handle, mode.value | 0x0004)
    except Exception:
        pass


def center_and_resize_window(width: int = 190, height: int = 60):
    """Resize and center the console window on the primary monitor."""
    try:
        import ctypes.wintypes
        kernel32 = ctypes.windll.kernel32
        user32 = ctypes.windll.user32

        subprocess.run(
            f"mode con: cols={width} lines={height}", shell=True, capture_output=True)

        hwnd = kernel32.GetConsoleWindow()
        if not hwnd:
            return

        screen_w = user32.GetSystemMetrics(0)
        screen_h = user32.GetSystemMetrics(1)

        rect = ctypes.wintypes.RECT()
        user32.GetWindowRect(hwnd, ctypes.byref(rect))
        win_w = rect.right - rect.left
        win_h = rect.bottom - rect.top

        x = (screen_w - win_w) // 2
        y = (screen_h - win_h) // 2
        user32.SetWindowPos(hwnd, 0, x, y, 0, 0, 0x0001)
        user32.ShowWindow(hwnd, 1)
    except Exception:
        pass


def ensure_console():
    """Attach a console if none exists."""
    try:
        kernel32 = ctypes.windll.kernel32
        if kernel32.GetConsoleWindow() == 0:
            kernel32.AllocConsole()
    except Exception:
        pass


if __name__ == "__main__":
    ensure_console()
    enable_vt_mode()                 # ensure 24‑bit color support
    center_and_resize_window(width=190, height=60)
    app = UplinkManagerApp()
    app.run()
