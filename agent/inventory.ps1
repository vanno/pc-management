<#
  Inventaire d'un PC Windows, lancé par l'agent MeshCentral (compte SYSTEM).

  Compatible Windows PowerShell 5.1, sans module externe, en lecture seule :
  le script ne modifie rien sur le poste.

  Sortie : une seule ligne
      PNINV1:<jeton>:<JSON encodé en base64 UTF-8>
  Le jeton (variable PNINV_NONCE posée par le worker) est propre à chaque
  poste et à chaque passage : le worker vérifie que la réponse reçue est bien
  celle du poste interrogé.
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
$csp  = Get-Cim 'Win32_ComputerSystemProduct' | Select-Object -First 1
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
    bios_date     = Format-Date $bios.ReleaseDate
    # Lenovo y met le nom commercial (« IdeaPad 5 Pro 16ACH6 ») ; vide ou
    # répété chez d'autres fabricants.
    family        = ("$($csp.Version)").Trim()
    sku           = ("$($cs.SystemSKUNumber)").Trim()
    uuid          = $csp.UUID
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
# Santé des disques (schéma 2). Get-PhysicalDisk et Get-StorageReliabilityCounter
# (module Storage, Windows 8 et suivants) donnent l'état vu par Windows et les
# compteurs SMART : usure (% de la durée de vie prévue consommée, 0 = neuf),
# température, heures sous tension, erreurs non corrigées. Le numéro de disque
# (DeviceId) est l'Index de Win32_DiskDrive. Un compteur absent reste nul :
# beaucoup de disques USB et certains SATA n'en donnent aucun.
$physical = @{}
foreach ($pd in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
    $rc = $null
    try { $rc = $pd | Get-StorageReliabilityCounter -ErrorAction Stop } catch { }
    $physical["$($pd.DeviceId)"] = [ordered]@{
        health         = "$($pd.HealthStatus)"
        media          = "$($pd.MediaType)"
        bus            = "$($pd.BusType)"
        wear_pct       = if ($rc -and $null -ne $rc.Wear) { [int]$rc.Wear } else { $null }
        temperature_c  = if ($rc -and $rc.Temperature) { [int]$rc.Temperature } else { $null }
        power_on_hours = if ($rc -and $null -ne $rc.PowerOnHours) { [int64]$rc.PowerOnHours } else { $null }
        read_errors    = if ($rc -and $null -ne $rc.ReadErrorsUncorrected) { [int64]$rc.ReadErrorsUncorrected } else { $null }
        write_errors   = if ($rc -and $null -ne $rc.WriteErrorsUncorrected) { [int64]$rc.WriteErrorsUncorrected } else { $null }
    }
}
# L'alerte SMART du disque lui-même (surtout SATA ; les NVMe ne la donnent pas toujours).
$predict = @(Get-Cim 'MSStorageDriver_FailurePredictStatus' 'root\wmi')

$systemDisk = $null
try { $systemDisk = [int](Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop | Select-Object -First 1).DiskNumber } catch { }

$disks = @(Get-Cim 'Win32_DiskDrive' | ForEach-Object {
    $d = $_
    $h = $physical["$($d.Index)"]
    $failing = $null
    foreach ($p in $predict) {
        if ($d.PNPDeviceID -and ("$($p.InstanceName)").StartsWith("$($d.PNPDeviceID)", [StringComparison]::OrdinalIgnoreCase)) { $failing = [bool]$p.PredictFailure }
    }
    [ordered]@{
        index          = [int]$d.Index
        model          = $d.Model
        serial         = ("$($d.SerialNumber)").Trim()
        size_bytes     = [int64]$d.Size
        interface      = $d.InterfaceType
        system         = ($null -ne $systemDisk -and [int]$d.Index -eq $systemDisk)
        health         = if ($h) { $h.health } else { $null }
        media          = if ($h) { $h.media } else { $null }
        bus            = if ($h) { $h.bus } else { $null }
        wear_pct       = if ($h) { $h.wear_pct } else { $null }
        temperature_c  = if ($h) { $h.temperature_c } else { $null }
        power_on_hours = if ($h) { $h.power_on_hours } else { $null }
        read_errors    = if ($h) { $h.read_errors } else { $null }
        write_errors   = if ($h) { $h.write_errors } else { $null }
        predict_failure = $failing
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
    # Le nombre de cycles n'est pas donné par toutes les batteries (0 ou absent).
    $cycles = Get-Cim 'BatteryCycleCount' 'root\wmi' | Select-Object -First 1
    $battery = [ordered]@{
        charge_percent     = $bat.EstimatedChargeRemaining
        designed_mwh       = $design.DesignedCapacity
        full_charged_mwh   = $full.FullChargedCapacity
        health_percent     = $health
        cycle_count        = if ($cycles -and $cycles.CycleCount -gt 0) { [int]$cycles.CycleCount } else { $null }
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

# --- Licences -------------------------------------------------------------------
# Windows : la licence active du système (ApplicationID de Windows), sans la
# clé. Le canal dit d'où elle vient (OEM du fabricant, Retail achetée,
# Volume). LicenseStatus : 1 activée, 0 non licenciée, 2 à 6 délai de grâce
# ou notification. La clé inscrite dans le BIOS n'est pas lue, seulement sa présence.
$winLicense = $null
$slp = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($slp) {
    $sls = Get-Cim 'SoftwareLicensingService' | Select-Object -First 1
    $winLicense = [ordered]@{
        status       = [int]$slp.LicenseStatus
        name         = $slp.Name
        description  = $slp.Description
        channel      = $slp.ProductKeyChannel
        partial_key  = $slp.PartialProductKey
        firmware_key = [bool]("$($sls.OA3xOriginalProductKey)").Trim()
    }
}

# vMix : l'édition (Basic HD, HD, 4K, Pro...) n'est lisible que vMix ouvert, par
# son API web locale (port 8088 par défaut). Lecture seule, deux secondes au plus.
$vmix = $null
if (Get-Process -Name 'vMix64', 'vMix' -ErrorAction SilentlyContinue) {
    $vmix = [ordered]@{ running = $true; version = $null; edition = $null }
    try {
        $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8088/api' -UseBasicParsing -TimeoutSec 2
        $x = [xml]$r.Content
        $vmix.version = $x.vmix.version
        $vmix.edition = $x.vmix.edition
    } catch { }
}

# --- Assemblage ------------------------------------------------------------------
$result = [ordered]@{
    schema         = 2
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
    licenses       = [ordered]@{ windows = $winLicense; vmix = $vmix }
}

$json = $result | ConvertTo-Json -Depth 7 -Compress
'PNINV1:' + $env:PNINV_NONCE + ':' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
