Function Deploy-PAYGO-Assessment {
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
        Write-Verbose $connectionString
        $connection.Open()

        $version_check = "
        SELECT CAST(ROUND(CAST(CAST(SERVERPROPERTY('ProductVersion') AS VARCHAR(4)) AS MONEY),0) AS INT)
        "
        $versioncommand = new-object system.data.sqlclient.sqlcommand($version_check,$connection)
        $version = $versioncommand.ExecuteScalar()
        if ($version -lt 13) {
            Write-Host "Only SQL Server 2016 and newer are supported for this assessment. Skipping server $server ..."
            continue
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
            continue
        }

        $Agent_check = "SELECT startup_type FROM sys.dm_server_services WHERE UPPER(filename) LIKE '%SQLAGENT.EXE%'"
        $Agentcommand = new-object system.data.sqlclient.sqlcommand($Agent_check,$connection)
        $AgentStartupType = $Agentcommand.ExecuteScalar()
        if ($AgentStartupType -ne 2) {
            Write-Host "SQL Server Agent is not configured for automatic start. Skipping server $server ..."
            continue
        }

        $Agent_check = "SELECT status FROM sys.dm_server_services WHERE UPPER(filename) LIKE '%SQLAGENT.EXE%'"
        $Agentcommand = new-object system.data.sqlclient.sqlcommand($Agent_check,$connection)
        $AgentStatus = $Agentcommand.ExecuteScalar()
        if ($AgentStatus -ne 4) {
            Write-Host "SQL Server Agent is currently not running. Skipping server $server ..."
            continue
        }

        $extsession = "
        IF NOT EXISTS (SELECT * FROM sys.server_event_sessions WHERE name = 'PAYGO')
        BEGIN
        CREATE EVENT SESSION [PAYGO] ON SERVER 
        ADD EVENT sqlserver.auto_stats(
        WHERE ([duration] > (0) AND [database_id] > (4) AND [sample_percentage]>(0))
		)
        ADD TARGET package0.ring_buffer
        WITH (MAX_MEMORY=4096 KB,EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,MAX_DISPATCH_LATENCY=30 SECONDS,MAX_EVENT_SIZE=0 KB,MEMORY_PARTITION_MODE=NONE,TRACK_CAUSALITY=OFF,STARTUP_STATE=ON)
        END
        "
        $extcommand = New-Object System.Data.SqlClient.SqlCommand($extsession, $connection)
        $extcommand.ExecuteNonQuery() | Out-Null
        $extsession = "
        IF EXISTS (SELECT * FROM sys.server_event_sessions WHERE name = 'PAYGO')
        ALTER EVENT SESSION [PAYGO] ON SERVER STATE = START
        "
        $extcommand = New-Object System.Data.SqlClient.SqlCommand($extsession, $connection)
        $extcommand.ExecuteNonQuery() | Out-Null

        $extproperty = "
        DECLARE @StartDate VARCHAR(19) = CONVERT(DATETIME2(7),GETDATE(),126)
        IF NOT EXISTS (SELECT * FROM msdb.sys.extended_properties WHERE name = 'PAYGO-Start')
            EXEC msdb.sys.sp_addextendedproperty @name = 'PAYGO-Start', @value = @StartDate
        ELSE
            EXEC msdb.sys.sp_updateextendedproperty @name = 'PAYGO-Start', @value = @StartDate
        "
        $extcommand = New-Object System.Data.SqlClient.SqlCommand($extproperty, $connection)
        $extcommand.ExecuteNonQuery() | Out-Null

        $connection.Close()

        $script = Get-Content .\Collect.sql -Encoding UTF8 -Raw
        if (!($script)) {
            break
        }
      
        try {
            [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.Smo") | Out-Null
            [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.Management.Smo") | Out-Null
        
            $JobName = $Global:JobName
            # Create the job
            $smo = New-Object -TypeName  Microsoft.SQLServer.Management.Smo.Server($server) #| Out-Null
      
            if (($smo.JobServer.Jobs | Select-Object -ExpandProperty Name)  -contains $JobName) {
                $sqlJob = $smo.JobServer.Jobs | Where-Object { $_.Name -eq $JobName }
                $sqlJob.OwnerLoginName = 'sa'
                #$sqlJob.Category = "Database Maintenance"
                $sqlJob.Description = "Source: $($Global:JobName) Assessment"
                #$sqlJob.EmailLevel = [Microsoft.SqlServer.Management.Smo.Agent.CompletionAction]::OnFailure
                #$sqlJob.PageLevel = [Microsoft.SqlServer.Management.Smo.Agent.CompletionAction]::OnFailure
                #$sqlJob.EventLogLevel = [Microsoft.SqlServer.Management.Smo.Agent.CompletionAction]::OnFailure
            }
            else {
                $sqlJob = New-Object -TypeName Microsoft.SqlServer.Management.SMO.Agent.Job -argumentlist $smo.JobServer, $JobName #| Out-Null
                $sqlJob.OwnerLoginName = 'sa'
                $sqlJob.Create()
                $sqlJob.ApplyToTargetServer("(local)")
                #$sqlJob.Category = "Database Maintenance"
                $sqlJob.Description = "Source: $($Global:JobName) Assessment"
                #$sqlJob.EmailLevel = [Microsoft.SqlServer.Management.Smo.Agent.CompletionAction]::OnFailure
                #$sqlJob.PageLevel = [Microsoft.SqlServer.Management.Smo.Agent.CompletionAction]::OnFailure
                #$sqlJob.EventLogLevel = [Microsoft.SqlServer.Management.Smo.Agent.CompletionAction]::OnFailure
            }
      
            # Setup the job step
            if (($sqlJob.JobSteps | Select-Object -ExpandProperty Name) -contains $JobName) {
                $sqlJobStep = $sqlJob.JobSteps | Where-Object { $_.Name -eq $JobName }
                $sqlCommand = $script   
                $sqlJobStep.SubSystem = "TransactSQL"
                $sqlJobStep.DatabaseName = "msdb"
                $sqlJobStep.Command = $sqlCommand
                $sqlJobStep.Alter() 
            }
            else {
                $sqlJobStep = New-Object -TypeName Microsoft.SqlServer.Management.SMO.Agent.JobStep -argumentlist $sqlJob, $JobName
                $sqlCommand = $script   
                $sqlJobStep.SubSystem = "TransactSQL"
                $sqlJobStep.DatabaseName = "msdb"
                $sqlJobStep.Command = $sqlCommand
                $sqlJobStep.Create() 
            }
            $sqlJobStep.OnSuccessAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::QuitWithSuccess
            $sqlJobStep.OnFailAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::QuitWithSuccess
      
            #Now add a schedule to our job to finish it off
            if (($sqlJob.JobSchedules | Select-Object -ExpandProperty Name) -contains $JobName) {
                $SQLJobSchedule = $sqlJob.JobSchedules | Where-Object { $_.Name -eq $JobName }
                #Need to use the built in types for Frequency, in this case we'll run it every day
                $SQLJobSchedule.FrequencyTypes =  [Microsoft.SqlServer.Management.SMO.Agent.FrequencyTypes]::Weekly
                $SQLJobSchedule.FrequencyInterval = 127 #every day
                $SQLJobSchedule.FrequencySubDayTypes = [Microsoft.SqlServer.Management.SMO.Agent.FrequencySubDayTypes]::Hour
                $SQLJobSchedule.FrequencySubDayInterval = 1
                $SQLJobSchedule.FrequencyRecurrenceFactor = 1
                $SQLJobSchedule.ActiveStartTimeofDay = 0
                
                #Set the job to be active from now
                $SQLJobSchedule.ActiveStartDate = get-date
                $SQLJobSchedule.Alter()
            } 
            else {
                $SQLJobSchedule =  New-Object -TypeName Microsoft.SqlServer.Management.SMO.Agent.JobSchedule -argumentlist $SQLJob, $JobName
                #Need to use the built in types for Frequency, in this case we'll run it every day
                $SQLJobSchedule.FrequencyTypes =  [Microsoft.SqlServer.Management.SMO.Agent.FrequencyTypes]::Weekly
                $SQLJobSchedule.FrequencyInterval = 127 #every day
                $SQLJobSchedule.FrequencySubDayTypes = [Microsoft.SqlServer.Management.SMO.Agent.FrequencySubDayTypes]::Hour
                $SQLJobSchedule.FrequencySubDayInterval = 1
                $SQLJobSchedule.FrequencyRecurrenceFactor = 1
                $SQLJobSchedule.ActiveStartTimeofDay = 0
                
                #Set the job to be active from now
                $SQLJobSchedule.ActiveStartDate = get-date
                $SQLJobSchedule.Create()
            }
            $sqlJob.Alter()
        }
        catch {
            $ErrorString = $_ | format-list -force | Out-String
            Write-Host $ErrorString -ForegroundColor Red  
        }
    
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