SET NOCOUNT ON
DECLARE @DBBinData VARBINARY(MAX)
DECLARE @DBBinSet VARBINARY(8)
DECLARE @DBBinDate VARBINARY(4)
DECLARE @DBBinFLags VARBINARY(2)
DECLARE @PAYGO_Table TABLE (
	[DBName]		VARCHAR(255),
	[TimeStamp]		SMALLDATETIME,
	[Offline]		BIT,
	[ReadOnly]		BIT,
	[Secondary]		BIT,
	[SecondaryR]	BIT,
	[ReadData]		TINYINT,
	[WriteData]		TINYINT,
	[BackupF]		BIT,
	[BackupD]		BIT,
	[BackupL]		BIT,
	[CheckDB]		BIT,
	[AlterIdx]		BIT,
	[UpdStats]		BIT,
	[SimpleRM]		BIT
)

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


DECLARE @DBName VARCHAR(255)
DECLARE @BinLength INT
DECLARE @i INT

DECLARE PAYGO_Crs CURSOR FOR SELECT REPLACE(name,'PAYGO:',''), DECOMPRESS(CAST(value AS VARBINARY(8000))) FROM [msdb].sys.extended_properties WHERE name LIKE 'PAYGO:%'

OPEN PAYGO_Crs 
FETCH NEXT FROM PAYGO_Crs INTO @DBName, @DBBinData

WHILE @@FETCH_STATUS = 0
BEGIN
	SET @BinLength = (LEN(@DBBinData)-16) / 8
	PRINT CAST(@BinLength AS VARCHAR) + ': ' + @DBName
	SET @i = 0
	WHILE @i < @BinLength
	BEGIN
		SET @DBBinSet = SUBSTRING(@DBBinData, 16 + (@i*8)+1, 8)
		SET @DBBinDate = SUBSTRING(@DBBinSet,1,4)
		SET @ReadData = CAST(SUBSTRING(@DBBinSet,5,1) AS TINYINT)
		SET @WriteData = CAST(SUBSTRING(@DBBinSet,6,1) AS TINYINT)
		--PRINT CAST(@DBBinDate AS SMALLDATETIME)
		SET @DBBinFLags = SUBSTRING(@DBBinSet,7,2)

		INSERT INTO @PAYGO_Table ([DBName],[TimeStamp],[Offline],[ReadOnly],[Secondary],[SecondaryR],[ReadData],[WriteData],[BackupF],[BackupD],[BackupL],[CheckDB],[AlterIdx],[UpdStats],[SimpleRM])
		VALUES
		(
			@DBName,
			CAST(@DBBinDate AS SMALLDATETIME),
			(@DBBinFLags & @Offline),
			(@DBBinFLags & @ReadOnly),
			(@DBBinFLags & @Secondary),
			(@DBBinFLags & @SecondaryR),
			@ReadData,
			@WriteData,
			--(@DBBinFLags & @ReadData),
			--(@DBBinFLags & @WriteData),
			(@DBBinFLags & @BackupF),
			(@DBBinFLags & @BackupD),
			(@DBBinFLags & @BackupL),
			(@DBBinFLags & @CheckDB),
			(@DBBinFLags & @AlterIdx),
			(@DBBinFLags & @UpdStats),
			(@DBBinFLags & @SimpleRM)
		)

		SET @i = @i + 1
	END

	FETCH NEXT FROM PAYGO_Crs INTO @DBName, @DBBinData
END
CLOSE PAYGO_Crs 
DEALLOCATE PAYGO_Crs 

SELECT * FROM @PAYGO_Table 
--WHERE DBName = '_DBA'
--WHERE BackupL = 1
--GROUP BY DBName
ORDER BY 1,2
