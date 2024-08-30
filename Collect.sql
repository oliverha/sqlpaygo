SET QUOTED_IDENTIFIER ON
SET NOCOUNT ON
DECLARE @MaxRowsPerDB INT = 550 --- 2160
DECLARE @NOW DATETIME2(7) = GETDATE()
DECLARE @SQLSTARTTIME DATETIME2(7) = (SELECT sqlserver_start_time FROM sys.dm_os_sys_info)
DECLARE @AssessmentStartDate DATETIME2(7) = (SELECT CAST([value] AS DATETIME2(7)) FROM msdb.sys.extended_properties WHERE name = 'PAYGO-Start')
DECLARE @LastRunDate DATETIME2(7) = (SELECT CAST([value] AS DATETIME2(7)) FROM msdb.sys.extended_properties WHERE name = 'PAYGO-LastRun')
DECLARE @DBID INT
DECLARE @DBNAME VARCHAR(255)
DECLARE @DBSTATUS VARCHAR(50)
DECLARE @DBRM TINYINT
DECLARE @DBISREADONLY BIT
DECLARE @DBUPDATEABILITY VARCHAR(50)
DECLARE @SECONDARYRO INT
BEGIN TRY
	DECLARE @path VARCHAR(MAX)
	SELECT @path=SUBSTRING(path, 1, LEN(path) - CHARINDEX('_', REVERSE(path))) + '.trc' FROM sys.traces WHERE is_default = 1
	DECLARE @AlterIndexTable TABLE (DatabaseID INT)
	INSERT INTO @AlterIndexTable
	SELECT DISTINCT t.DatabaseID FROM sys.fn_trace_gettable(@path, DEFAULT) t WHERE EventClass = 164 AND IndexID > 0 AND EventSubClass = 1 AND StartTime > DATEADD(HH,-1,@NOW)
END TRY
BEGIN CATCH
END CATCH
BEGIN TRY
	DECLARE @UpdateStatsTable TABLE (DatabaseID INT, ObjectID INT, StatsID INT)
	INSERT INTO @UpdateStatsTable
	SELECT 
		DISTINCT
		e.event_data.value('(data[@name="database_id"]/value)[1]', 'int') AS database_id,
		e.event_data.value('(data[@name="object_id"]/value)[1]', 'int') AS object_id,
		e.event_data.value('(data[@name="index_id"]/value)[1]', 'int') AS stats_id--,
		--e.event_data.value('(data[@name="sample_percentage"]/value)[1]', 'int') AS sample_percentage,
		--DATEADD(mi, DATEDIFF(mi, GETUTCDATE(), GETDATE()), e.event_data.value('(@timestamp)[1]', 'datetime2')) AS timestamp
	FROM 
		(SELECT CAST(target_data AS XML) AS event_data
		 FROM sys.dm_xe_session_targets AS t
		 JOIN sys.dm_xe_sessions AS s
		 ON t.event_session_address = s.address
		 WHERE s.name = 'PAYGO'
		 AND t.target_name = 'ring_buffer') AS x
	CROSS APPLY 
		x.event_data.nodes('/RingBufferTarget/event') AS e(event_data)
	WHERE 
		DATEADD(mi, DATEDIFF(mi, GETUTCDATE(), GETDATE()), e.event_data.value('(@timestamp)[1]', 'datetime2')) > DATEADD(HH, -1, @NOW)
	OPTION (RECOMPILE, MAXDOP 1, FORCE ORDER, NO_PERFORMANCE_SPOOL);
END TRY
BEGIN CATCH
END CATCH

DECLARE @UserReads	BIGINT
DECLARE @UserWrites	BIGINT
DECLARE @LastReads	BIGINT
DECLARE @LastWrites	BIGINT
DECLARE @ReadData	TINYINT
DECLARE @WriteData	TINYINT

DECLARE @Offline	INT = 1
DECLARE @ReadOnly	INT = 2
DECLARE @Secondary	INT = 4
DECLARE @SecondaryR INT = 8
DECLARE @BackupF	INT = 16
DECLARE @BackupD	INT = 32
DECLARE @BackupL	INT = 64
DECLARE @CheckDB	INT = 128
DECLARE @AlterIdx	INT = 256
DECLARE @UpdStats	INT = 512
DECLARE @SimpleRM	INT = 1024

DECLARE @bOffline		BIT
DECLARE @bReadOnly		BIT
DECLARE @bSecondary		BIT
DECLARE @bSecondaryR	BIT
DECLARE @bBackupF		BIT
DECLARE @bBackupD		BIT
DECLARE @bBackupL		BIT
DECLARE @bCheckDB		BIT
DECLARE @bAlterIdx		BIT
DECLARE @bUpdStats		BIT
DECLARE @bSimpleRM		BIT

DECLARE @DBINFO TABLE ([ParentObject] VARCHAR(200), [Object] VARCHAR(255), [Field] VARCHAR(50), [VALUE] VARCHAR(255))
DECLARE @DBSTATS TABLE (ObjectID INT, StatsID INT)
DECLARE @DBStatsUpdateCount BIGINT
DECLARE @DBStatsCount BIGINT

DECLARE @SQLCMD NVARCHAR(max)
DECLARE @binFlags VARBINARY(2);
DECLARE @binTime VARBINARY(4) = CAST(CAST(@NOW AS SMALLDATETIME) AS VARBINARY(4)) --CAST((YEAR(GETDATE())-2000) * 1000000 + (MONTH(GETDATE())) * 10000 + (DAY(GETDATE())) * 100 + DATEPART(HH,(GETDATE())) AS varbinary(4))
DECLARE @DBPropName VARCHAR(255)
DECLARE @DBBinData VARBINARY(MAX)
DECLARE @DBBinDataNew VARBINARY(MAX)
DECLARE @DBBinDataNewCompressed VARBINARY(8000)
DECLARE @BitMask INT = 0;

DECLARE DB_CRS CURSOR READ_ONLY FORWARD_ONLY FOR SELECT d.database_id, name, state_desc, is_read_only, recovery_model, CAST(DATABASEPROPERTYEX(name, 'UpdateAbility') AS varchar(50)), ISNULL(CAST(ar.secondary_role_allow_connections AS int),-1)
FROM sys.databases d
LEFT JOIN sys.dm_hadr_database_replica_states rs ON d.database_id = rs.database_id
LEFT JOIN sys.availability_replicas ar ON rs.replica_id = ar.replica_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
WHERE 1=1
    AND ISNULL(ars.is_local,1) = 1
	AND d.database_id > 4 AND d.name NOT IN ('distribution','SSISDB')
ORDER BY name
OPEN DB_CRS
FETCH NEXT FROM DB_CRS INTO @DBID, @DBNAME, @DBSTATUS, @DBISREADONLY, @DBRM, @DBUPDATEABILITY, @SECONDARYRO
WHILE @@FETCH_STATUS = 0
BEGIN
	SET @bOffline		= 0
	SET @bReadOnly		= 0
	SET @bSecondary		= 0
	SET @bSecondaryR	= 0
	SET @ReadData		= 0
	SET @WriteData		= 0
	SET @bBackupF		= 0
	SET @bBackupD		= 0
	SET @bBackupL		= 0
	SET @bCheckDB		= 0
	SET @bAlterIdx		= 0
	SET @bUpdStats		= 0
	SET @bSimpleRM		= 0
	
	IF @DBSTATUS = 'OFFLINE'
		SET @bOffline = 1
	ELSE
	BEGIN
		IF @DBISREADONLY = 1
			SET @bReadOnly = 1
		IF @DBRM = 3
			SET @bSimpleRM = 1
		IF @DBUPDATEABILITY = 'READ_ONLY' AND @SECONDARYRO >= 0
			SET @bSecondary = 1
		IF @DBUPDATEABILITY = 'READ_ONLY' AND @SECONDARYRO = 2
			SET @bSecondaryR = 1
		IF EXISTS (SELECT * FROM msdb.dbo.backupset WHERE database_name = @DBNAME AND type = 'D' AND backup_finish_date > DATEADD(HH,-1,@NOW))
			SET @bBackupF = 1
		IF EXISTS (SELECT * FROM msdb.dbo.backupset WHERE database_name = @DBNAME AND type = 'I' AND backup_finish_date > DATEADD(HH,-1,@NOW))
			SET @bBackupD = 1
		IF EXISTS (SELECT * FROM msdb.dbo.backupset WHERE database_name = @DBNAME AND type = 'L' AND backup_finish_date > DATEADD(HH,-1,@NOW))
			SET @bBackupL = 1
		BEGIN TRY
			SET @SQLCMD = 'DBCC DBINFO([' + @DBNAME + ']) WITH TABLERESULTS, NO_INFOMSGS'
			DELETE @DBINFO
			INSERT INTO @DBINFO
			EXEC(@SQLCMD)
			IF (SELECT CAST([VALUE] AS datetime2(7)) FROM @DBINFO WHERE [Field] = 'dbi_dbccLastKnownGood') > DATEADD(HH,-1,@NOW)
				SET @bCheckDB = 1
		END TRY
		BEGIN CATCH
		END CATCH
		IF @bSecondary = 0 OR @SECONDARYRO = 2
		BEGIN
			BEGIN TRY
				SET @SQLCMD = N'USE [' + @DBNAME + ']; SELECT @UserReads = SUM(user_seeks+user_scans+user_lookups) FROM sys.tables t INNER JOIN sys.dm_db_index_usage_stats s ON s.database_id = DB_ID() AND t.object_id = s.object_id WHERE t.is_ms_shipped = 0 AND t.type = ''U'''
				EXEC sp_executesql @SQLCMD, N'@UserReads BIGINT OUTPUT', @UserReads = @UserReads OUTPUT
				SET @UserReads = ISNULL(@UserReads,0)
			END TRY
			BEGIN CATCH 
			END CATCH
			BEGIN TRY
				SET @SQLCMD = N'USE [' + @DBNAME + ']; SELECT @UserWrites = SUM(user_updates) FROM sys.tables t INNER JOIN sys.dm_db_index_usage_stats s ON s.database_id = DB_ID() AND t.object_id = s.object_id WHERE t.is_ms_shipped = 0 AND t.type = ''U'''
				EXEC sp_executesql @SQLCMD, N'@UserWrites BIGINT OUTPUT', @UserWrites = @UserWrites OUTPUT
				SET @UserWrites = ISNULL(@UserWrites,0)
			END TRY
			BEGIN CATCH
			END CATCH
		END
		IF @bSecondary = 0
		BEGIN
			--IF EXISTS (SELECT t.* FROM sys.fn_trace_gettable(@path,0) t	WHERE DatabaseID = @DBID AND EventClass = 164 AND IndexID > 0 AND EventSubClass = 1 AND StartTime > DATEADD(HH,-1,GETDATE()))
			IF EXISTS (SELECT * FROM @AlterIndexTable WHERE DatabaseID = @DBID)
				SET @bAlterIdx = 1

			IF @AssessmentStartDate IS NULL
			BEGIN
				BEGIN TRY
					SET @SQLCMD = 'USE [' + @DBNAME + ']; SELECT DISTINCT s.object_id, s.stats_id FROM sys.tables t INNER JOIN sys.stats s ON t.object_id =  s.object_id WHERE t.is_ms_shipped = 0 AND t.type = ''U'''
					DELETE @DBSTATS
					INSERT INTO @DBSTATS
					EXEC (@SQLCMD)
					SET @DBStatsCount = ISNULL((SELECT COUNT(*) FROM @DBSTATS),1)
				END TRY
				BEGIN CATCH
				END CATCH
				BEGIN TRY
					SET @SQLCMD = N'USE [' + @DBNAME + ']; SELECT DISTINCT s.object_id, s.stats_id FROM sys.tables t INNER JOIN sys.stats s ON t.object_id =  s.object_id WHERE t.is_ms_shipped = 0 AND t.type = ''U'' AND STATS_DATE(s.object_id, s.stats_id) > DATEADD(HH,-1,@NOW)'
					DELETE @DBSTATS
					INSERT INTO @DBSTATS
					EXEC sp_executesql @SQLCMD, N'@NOW DATETIME2(7)', @NOW=@NOW
					SET @DBStatsUpdateCount = ISNULL((SELECT COUNT(*) FROM @DBSTATS),0)
				END TRY
				BEGIN CATCH
				END CATCH
				IF @DBStatsUpdateCount > LOG(@DBStatsCount)
					SET @bUpdStats = 1
			END
			IF @AssessmentStartDate < DATEADD(HH, -1, GETDATE())
			BEGIN
				BEGIN TRY
					SET @SQLCMD = N'USE [' + @DBNAME + ']; SELECT DISTINCT s.object_id, s.stats_id FROM sys.tables t INNER JOIN sys.stats s ON t.object_id =  s.object_id WHERE t.is_ms_shipped = 0 AND t.type = ''U'' AND STATS_DATE(s.object_id, s.stats_id) > DATEADD(HH,-1,@NOW)'
					DELETE @DBSTATS
					INSERT INTO @DBSTATS
					EXEC sp_executesql @SQLCMD, N'@NOW DATETIME2(7)', @NOW=@NOW
				END TRY
				BEGIN CATCH
				END CATCH
				IF EXISTS (SELECT * FROM @DBSTATS dbs LEFT JOIN @UpdateStatsTable ups ON ups.DatabaseID = @DBID AND dbs.ObjectID = ups.ObjectID AND dbs.StatsID = ups.StatsID WHERE ups.StatsID IS NULL)
					SET @bUpdStats = 1
			END
		END
	END

	SET @BitMask = 0
    IF @bOffline	= 1 SET @BitMask = @BitMask + @Offline
    IF @bReadOnly	= 1 SET @BitMask = @BitMask + @ReadOnly
    IF @bSecondary	= 1 SET @BitMask = @BitMask + @Secondary
    IF @bSecondaryR	= 1 SET @BitMask = @BitMask + @SecondaryR
    IF @bBackupF	= 1 SET @BitMask = @BitMask + @BackupF
    IF @bBackupD	= 1 SET @BitMask = @BitMask + @BackupD
    IF @bBackupL	= 1 SET @BitMask = @BitMask + @BackupL
    IF @bCheckDB	= 1 SET @BitMask = @BitMask + @CheckDB
    IF @bAlterIdx	= 1 SET @BitMask = @BitMask + @AlterIdx
    IF @bUpdStats	= 1 SET @BitMask = @BitMask + @UpdStats
	IF @bSimpleRM	= 1 SET @BitMask = @BitMask + @SimpleRM
	SET @binFlags = CAST(@BitMask AS varbinary(2))
	
	SET @DBPropName = 'PAYGO:' + @DBNAME
	IF EXISTS (SELECT * FROM [msdb].sys.extended_properties WHERE class = 0 AND name = @DBPropName)
	BEGIN
		SET @DBBinData = (SELECT CONVERT(VARBINARY(MAX),[value]) FROM [msdb].sys.extended_properties WHERE class = 0 AND name = @DBPropName)
		IF @DBBinData IS NULL
		BEGIN
			SET @ReadData = 0
			SET @WriteData = 0
			SET @DBBinDataNew = @binTime+CAST(@ReadData AS VARBINARY(1))+CAST(@WriteData AS VARBINARY(1))+@binFlags
			IF LEN(@DBBinDataNew) <> 8
				RAISERROR ('Wrong data length (A)!', 0, 1) WITH NOWAIT
			SET @DBBinDataNew = CAST(@UserReads AS VARBINARY(8))+CAST(@UserWrites AS VARBINARY(8))+@DBBinDataNew
			IF LEN(@DBBinDataNew) <> 24
				RAISERROR ('Wrong data length (B)!', 0, 1) WITH NOWAIT
			SET @DBBinDataNewCompressed = COMPRESS(@DBBinDataNew)
			EXEC [msdb].sys.sp_updateextendedproperty @name = @DBPropName, @value = @DBBinDataNewCompressed
		END
		ELSE
		BEGIN
			SET @DBBinData	= DECOMPRESS(@DBBinData)
			IF LEN(@DBBinData) % 8 <> 0
			BEGIN
				--PRINT LEN(@DBBinData)
				RAISERROR ('Wrong data length (C)!', 0, 1) WITH NOWAIT
			END
			IF (LEN(@DBBinData) - 16) % 8 <> 0
				RAISERROR ('Wrong data length (D)!', 0, 1) WITH NOWAIT
			SET @LastReads	= CAST(SUBSTRING(@DBBinData,1,8) AS BIGINT)
			SET @LastWrites	= CAST(SUBSTRING(@DBBinData,9,8) AS BIGINT)
			IF DATEDIFF(MI,@SQLSTARTTIME,@NOW) < 60 AND ISNULL(@LastRunDate,'19000101') < @SQLSTARTTIME
			BEGIN
				SET @LastReads = 0
				SET @LastWrites = 0
			END
			SET @ReadData	= CASE WHEN POWER(@UserReads - @LastReads,0.25) > 255 THEN 255 ELSE POWER(@UserReads - @LastReads,0.25) END
			SET @WriteData	= CASE WHEN POWER(@UserWrites - @LastWrites,0.25) > 255 THEN 255 ELSE POWER(@UserWrites - @LastWrites,0.25) END
			IF ((LEN(@DBBinData) - 16) / 8) >= @MaxRowsPerDB
			BEGIN
				SET @DBBinData = SUBSTRING(@DBBinData,16+ ( ((LEN(@DBBinData) - 16) / 8) - @MaxRowsPerDB + 1  )*8   +1,((@MaxRowsPerDB-1)*8))
			END
			ELSE
			BEGIN
				SET @DBBinData = SUBSTRING(@DBBinData,16+1,LEN(@DBBinData)-16)
			END
			SET @DBBinDataNew = @binTime + CAST(@ReadData AS VARBINARY(1)) + CAST(@WriteData AS VARBINARY(1)) + @binFlags
			IF LEN(@DBBinDataNew) <> 8
				RAISERROR ('Wrong data length (F)!', 0, 1) WITH NOWAIT
			SET @DBBinDataNew = @DBBinData + @DBBinDataNew
			IF LEN(@DBBinData) % 8 <> 0
				RAISERROR ('Wrong data length (G)!', 0, 1) WITH NOWAIT
			SET @DBBinDataNew = CAST(@UserReads AS VARBINARY(8)) + CAST(@UserWrites AS VARBINARY(8)) + @DBBinDataNew
			SET @DBBinDataNewCompressed = COMPRESS(@DBBinDataNew)
			EXEC [msdb].sys.sp_updateextendedproperty @name = @DBPropName, @value = @DBBinDataNewCompressed
		END
	END 
	ELSE
	BEGIN
		SET @ReadData = 0
		SET @WriteData = 0
		SET @DBBinDataNew = CAST(@UserReads AS VARBINARY(8))+CAST(@UserWrites AS VARBINARY(8))+@binTime+CAST(@ReadData AS VARBINARY(1))+CAST(@WriteData AS VARBINARY(1))+@binFlags
		--PRINT @DBBinDataNew
		--SET @DBBinDataNew = @binTime+@binFlags
		SET @DBBinDataNewCompressed = COMPRESS(@DBBinDataNew)
		EXEC [msdb].sys.sp_addextendedproperty @name = @DBPropName, @value = @DBBinDataNewCompressed
	END
	
	--SELECT @DBNAME, @bOffline, @bReadOnly, @bSecondary, @bSecondaryR, @bReadData, @bWriteData, @bBackupF, @bBackupD, @bBackupL, @bCheckDB, @bAlterIdx,  @bUpdStats, @binFlags, @binTime, @binTime+@binFlags

	FETCH NEXT FROM DB_CRS INTO @DBID, @DBNAME, @DBSTATUS, @DBISREADONLY, @DBRM, @DBUPDATEABILITY, @SECONDARYRO
END
CLOSE DB_CRS
DEALLOCATE DB_CRS

DECLARE @LastRun VARCHAR(19) = CONVERT(DATETIME2(7),@NOW,126)
IF NOT EXISTS (SELECT * FROM msdb.sys.extended_properties WHERE name = 'PAYGO-LastRun')
    EXEC msdb.sys.sp_addextendedproperty @name = 'PAYGO-LastRun', @value = @LastRun
ELSE
    EXEC msdb.sys.sp_updateextendedproperty @name = 'PAYGO-LastRun', @value = @LastRun
