function Cleanup-PAYGO-Assessment {
[CmdletBinding()] 
param (
    [string]$CMSServer,
    [string]$CMSFilter = "%",
    [string]$ServerListFile
)

if ($CMSServer -and $ServerList) {
    Write-Host "You can only select one deployment source. Central Management Server (CMS) or from a text file." -ForegroundColor Yellow
    return
}

if ($ServerListFile) {
    if ([System.Boolean](Test-Path $ServerListFile -PathType Leaf) -eq $false) {
        Write-Host "The selected file does not exist." -ForegroundColor Yellow
        return
    }
}

if ($CMSServer) {
    $stage = $CMSFilter
    $CMSQuery = "WITH CTE_CMS
    AS
    (
    --Anchor
    SELECT server_group_id, name, description, parent_id, 1 AS [level], CAST((name) AS VARCHAR(MAX)) AS CMSPath
    FROM msdb.dbo.sysmanagement_shared_server_groups AS A
    WHERE parent_id IS NULL AND server_type = 0
    UNION ALL
    --Recursive Member
    SELECT B.server_group_id, B.name, B.description, B.parent_id, C.[level] + 1 AS [Level], CAST((C.CMSPath + '\' + B.name) AS VARCHAR(MAX)) AS CMSPath
    FROM msdb.dbo.sysmanagement_shared_server_groups AS B
    JOIN CTE_CMS AS C 
    ON B.parent_id = C.server_group_id  
    )

    --SELECT CMSPath AS cms_path , B.name server_name, B.[description] AS server_description, A.name AS group_name, A.description AS group_description
    SELECT CMSPath AS cms_path , B.server_name, B.[description] AS server_description, A.name AS group_name, A.description AS group_description
    FROM CTE_CMS AS A
    INNER JOIN msdb.dbo.sysmanagement_shared_registered_servers AS B
    ON A.server_group_id=B.server_group_id
    WHERE UPPER(A.CMSPath) LIKE UPPER('%\$Stage%')
    ORDER BY CMSPath -- [level] DESC
    "
    $cmsconnectionString = "Server=$CMSServer;trustservercertificate=True;Integrated Security=True;"
    $cmsconnection = new-object system.data.SqlClient.SQLConnection($cmsconnectionString)

    $cmscommand = new-object system.data.sqlclient.sqlcommand($CMSQuery,$cmsconnection)
    $cmsconnection.Open()

	$cmsadapter = New-Object System.Data.sqlclient.sqlDataAdapter $cmscommand
	$cmsdataset = New-Object System.Data.DataSet
	$cmsadapter.Fill($cmsdataSet) | Out-Null

	$cmsconnection.Close()
	$CMSResults = $cmsdataSet.Tables[0]

    $selection = $CMSResults | Out-GridView -Title "Server List" -PassThru
    if ($selection) {
        $ServerList = $CMSResults | Select-Object -ExpandProperty server_name | Sort-Object
    }
    else {
        Write-Host "Cancelled ..."
        return
    }
}

if ($ServerListFile) {
    $ServerList = @()
    $ServerListContent = Get-Content -Path $ServerListFile
    foreach ($line in $ServerListContent) {
        if ($line) {
            $ServerList += $line.Trim()
        }
    }
    $ServerList = $ServerList | Sort-Object
}

foreach ($server in $ServerList) {
    try {
        $connectionString = "Server=$server;trustservercertificate=True;Integrated Security=True;Connect Timeout=3"
        $connection = new-object system.data.SqlClient.SQLConnection($connectionString)
        $connection.Open()

        $version_check = "
        SELECT CAST(ROUND(CAST(CAST(SERVERPROPERTY('ProductVersion') AS VARCHAR(4)) AS MONEY),0) AS INT)
        "
        $versioncommand = new-object system.data.sqlclient.sqlcommand($version_check,$connection)
        $version = $versioncommand.ExecuteScalar()

        if ($version -lt 13) {
            Write-Host "Only SQL Server 2016 and newer are supported for this assessment. Skipping server $server ..."
            break
        }

        $cag_check = "
        DECLARE @SQL NVARCHAR(MAX) = 'SELECT @CAG = COUNT(*) FROM sys.availability_groups AG INNER JOIN sys.availability_group_listeners AGL ON AG.group_id = AGL.group_id INNER JOIN sys.availability_group_listener_ip_addresses AGLI ON AGL.listener_id = AGLI.listener_id INNER JOIN sys.dm_exec_connections DEC ON AGLI.ip_address = DEC.local_net_address WHERE 1=1 AND AG.is_contained = 1 AND DEC.session_id = @@SPID'
        DECLARE @CAG TINYINT = 0
        IF CONVERT(INT,LEFT(CONVERT(VARCHAR(255),SERVERPROPERTY('ProductVersion')),2)) >= 16
            EXEC sp_executesql @SQL, N'@CAG TINYINT OUTPUT', @CAG = @CAG OUTPUT
        SELECT @CAG
        "
        $cagcommand = new-object system.data.sqlclient.sqlcommand($cag_check,$connection)
        $cag = $cagcommand.ExecuteScalar()

        if ($cag -eq 1) {
            Write-Host "Contained Availability Group connections are not supported. Skipping server $server ..."
            break
        }

        $extsession = "
        IF EXISTS (SELECT * FROM sys.server_event_sessions WHERE name = 'PAYGO')
        DROP EVENT SESSION [PAYGO] ON SERVER 
        "
        $extcommand = New-Object System.Data.SqlClient.SqlCommand($extsession, $connection)
        $extcommand.ExecuteNonQuery() | Out-Null

        $JobName = $Global:JobName
        $jobNameSafe = $JobName.Replace("'", "''")

        $deleteJob = "IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'$jobNameSafe') EXEC msdb.dbo.sp_delete_job @job_name = N'$jobNameSafe', @delete_unused_schedule = 1"
        $deleteJobCommand = New-Object System.Data.SqlClient.SqlCommand($deleteJob, $connection)
        $deleteJobCommand.ExecuteNonQuery() | Out-Null

        $dropExtendedProperties = @"
DECLARE @propName SYSNAME
DECLARE prop_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM msdb.sys.extended_properties
    WHERE [name] LIKE 'PAYGO:%'
       OR [name] IN ('PAYGO-Start', 'PAYGO-LastRun')

OPEN prop_cursor
FETCH NEXT FROM prop_cursor INTO @propName

WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC msdb.sys.sp_dropextendedproperty
        @name = @propName,
        @level0type = N'DATABASE',
        @level0name = N'msdb'

    FETCH NEXT FROM prop_cursor INTO @propName
END

CLOSE prop_cursor
DEALLOCATE prop_cursor
"@
        $dropExtendedPropertiesCommand = New-Object System.Data.SqlClient.SqlCommand($dropExtendedProperties, $connection)
        $dropExtendedPropertiesCommand.ExecuteNonQuery() | Out-Null

        $connection.Close()

    }
    catch [System.Data.SqlClient.SqlException] {
        if ($connection.State -eq [System.Data.ConnectionState]::Closed) {
            Write-Host "Could not connect to $server" -ForegroundColor Yellow
        }
        else {
            Write-Host "Error: $_"
        }
    }
    catch  {
        Write-Host "Error: $_"
    }
    finally {
        if ($connection.State -eq 'Open') {
            $connection.Close()
        }
    }
}

}