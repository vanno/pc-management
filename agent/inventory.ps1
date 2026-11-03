<#
  Inventaire d'un PC Windows, lancé par l'agent MeshCentral (compte SYSTEM).

  Compatible Windows PowerShell 5.1, sans module externe, en lecture seule :
  le script ne modifie rien sur le poste.

  Sortie : une seule ligne
      PNINV1:<JSON encodé en base64 UTF-8>
  Le base64 protège les accents des noms de logiciels pendant le transit par
  l'agent, et le préfixe permet au worker de retrouver la charge utile au
  milieu d'éventuels messages parasites.
#>

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

function Get-Cim([string]$Class, [string]$Namespace = 'root\cimv2') {
    try { Get-CimInstance -ClassName $Class -Namespace $Namespace -ErrorAction Stop }
    catch { @() }
}

function Format-Date($d) {
    if ($null -eq $d) { return $null }
    try { return ([datetime]$d).ToUniversalTime().ToString('o') } catch { return $null }
}

$cs   = Get-Cim 'Win32_ComputerSystem' | Select-Object -First 1
$bios = Get-Cim 'Win32_BIOS' | Select-Object -First 1
$os   = Get-Cim 'Win32_OperatingSystem' | Select-Object -First 1
$cv   = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

# --- Système -----------------------------------------------------------------
$system = [ordered]@{
    hostname      = $env:COMPUTERNAME
    manufacturer  = $cs.Manufacturer
    model         = $cs.Model
    serial        = $bios.SerialNumber
    bios_version  = $bios.SMBIOSBIOSVersion
    part_of_domain = [bool]$cs.PartOfDomain
    domain        = $cs.Domain
    ram_bytes     = [int64]$cs.TotalPhysicalMemory
}

$windows = [ordered]@{
    caption        = $os.Caption
    edition_id     = $cv.EditionID
    display_version = $cv.DisplayVersion
    build          = $os.BuildNumber
    ubr            = $cv.UBR
    architecture   = $os.OSArchitecture
    install_date   = Format-Date $os.InstallDate
    last_boot      = Format-Date $os.LastBootUpTime
}

# --- Processeur, mémoire, GPU -------------------------------------------------
$cpus = @(Get-Cim 'Win32_Processor' | ForEach-Object {
    [ordered]@{
        name    = ($_.Name -replace '\s+', ' ').Trim()
        cores   = $_.NumberOfCores
        threads = $_.NumberOfLogicalProcessors
        max_mhz = $_.MaxClockSpeed
    }
})

$memory = @(Get-Cim 'Win32_PhysicalMemory' | ForEach-Object {
    [ordered]@{
        slot         = $_.DeviceLocator
        capacity_bytes = [int64]$_.Capacity
        speed_mhz    = $_.Speed
        manufacturer = $_.Manufacturer
        part_number  = ("$($_.PartNumber)").Trim()
    }
})

$gpus = @(Get-Cim 'Win32_VideoController' | ForEach-Object {
    [ordered]@{
        name           = $_.Name
        driver_version = $_.DriverVersion
        driver_date    = Format-Date $_.DriverDate
        resolution     = if ($_.CurrentHorizontalResolution) { "$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)" } else { $null }
    }
})

# --- Stockage ------------------------------------------------------------------
$disks = @(Get-Cim 'Win32_DiskDrive' | ForEach-Object {
    [ordered]@{
        model      = $_.Model
        serial     = ("$($_.SerialNumber)").Trim()
        size_bytes = [int64]$_.Size
        interface  = $_.InterfaceType
    }
})

$volumes = @(Get-Cim 'Win32_LogicalDisk' | Where-Object { $_.DriveType -eq 3 } | ForEach-Object {
    [ordered]@{
        letter     = $_.DeviceID
        label      = $_.VolumeName
        size_bytes = [int64]$_.Size
        free_bytes = [int64]$_.FreeSpace
        filesystem = $_.FileSystem
    }
})

# --- Réseau --------------------------------------------------------------------
$adapters = @{}
Get-Cim 'Win32_NetworkAdapter' | Where-Object { $_.PhysicalAdapter } | ForEach-Object { $adapters[[int]$_.Index] = $_ }

$network = @(Get-Cim 'Win32_NetworkAdapterConfiguration' | Where-Object { $_.MACAddress -and $adapters.ContainsKey([int]$_.Index) } | ForEach-Object {
    $a = $adapters[[int]$_.Index]
    [ordered]@{
        name        = $a.NetConnectionID
        description = $_.Description
        mac         = $_.MACAddress
        connected   = ($a.NetConnectionStatus -eq 2)
        speed_bps   = $a.Speed
        dhcp        = [bool]$_.DHCPEnabled
        ipv4        = @($_.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
        gateway     = @($_.DefaultIPGateway | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
    }
})

# --- Batterie (portables) ------------------------------------------------------
$battery = $null
$bat = Get-Cim 'Win32_Battery' | Select-Object -First 1
if ($bat) {
    $design = Get-Cim 'BatteryStaticData' 'root\wmi' | Select-Object -First 1
    $full   = Get-Cim 'BatteryFullChargedCapacity' 'root\wmi' | Select-Object -First 1
    $health = $null
    if ($design.DesignedCapacity -gt 0 -and $full.FullChargedCapacity -gt 0) {
        $health = [math]::Round(100 * $full.FullChargedCapacity / $design.DesignedCapacity, 1)
    }
    $battery = [ordered]@{
        charge_percent     = $bat.EstimatedChargeRemaining
        designed_mwh       = $design.DesignedCapacity
        full_charged_mwh   = $full.FullChargedCapacity
        health_percent     = $health
    }
}

# --- Logiciels installés -------------------------------------------------------
# Clés Uninstall de la machine (64 et 32 bits). Les installations « par
# utilisateur » (HKCU) ne sont pas visibles depuis le compte SYSTEM : c'est
# une limite connue, signalée dans la sortie.
$uninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$seen = @{}
$software = @(foreach ($key in $uninstallKeys) {
    Get-ItemProperty $key | Where-Object {
        $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName -and -not $_.ReleaseType
    } | ForEach-Object {
        $id = "$($_.DisplayName)|$($_.DisplayVersion)"
        if (-not $seen.ContainsKey($id)) {
            $seen[$id] = $true
            [ordered]@{
                name         = ("$($_.DisplayName)").Trim()
                version      = $_.DisplayVersion
                publisher    = $_.Publisher
                install_date = $_.InstallDate
            }
        }
    }
})
$software = @($software | Sort-Object { $_.name })

# --- Assemblage ------------------------------------------------------------------
$result = [ordered]@{
    schema         = 1
    collected_at   = (Get-Date).ToUniversalTime().ToString('o')
    system         = $system
    windows        = $windows
    cpus           = $cpus
    memory         = $memory
    gpus           = $gpus
    disks          = $disks
    volumes        = $volumes
    network        = $network
    battery        = $battery
    software       = $software
    software_scope = 'machine'
}

$json = $result | ConvertTo-Json -Depth 6 -Compress
'PNINV1:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
