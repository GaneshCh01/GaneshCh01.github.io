
/*
===============================================================================
Project      : MSSQL-DBA-HealthCheck
Script       : HealthCheck.sql
Purpose      : Production-style SQL Server health assessment
Author       : Ganesh Chittalwar
Version      : 1.0
SQL Version  : SQL Server 2012+
Execution    : Read-only
===============================================================================

IMPORTANT:
- Run with appropriate permissions.
- This script does NOT modify databases.
- Review findings before taking corrective action.
- Some sections require VIEW SERVER STATE or SQL Agent permissions.

HEALTH CHECK AREAS
1. Instance information
2. SQL Server uptime
3. Database status
4. Recovery model
5. Database size
6. Backup status
7. Failed SQL Agent jobs
8. Blocking
9. Long-running requests
10. TempDB
11. Database file space
12. Health summary
===============================================================================
*/

SET NOCOUNT ON;

PRINT '==============================================================';
PRINT '        SQL SERVER PRODUCTION HEALTH CHECK';
PRINT '==============================================================';

PRINT '';
PRINT 'Execution Time: ' + CONVERT(varchar(30), GETDATE(), 120);
PRINT '';

/*===========================================================================
  1. SERVER / INSTANCE INFORMATION
===========================================================================*/

PRINT '--------------------------------------------------------------';
PRINT '1. SERVER / INSTANCE INFORMATION';
PRINT '--------------------------------------------------------------';

SELECT
    SERVERPROPERTY('ServerName') AS ServerName,
    SERVERPROPERTY('InstanceName') AS InstanceName,
    SERVERPROPERTY('MachineName') AS MachineName,
    SERVERPROPERTY('Edition') AS Edition,
    SERVERPROPERTY('ProductVersion') AS ProductVersion,
    SERVERPROPERTY('ProductLevel') AS ProductLevel,
    SERVERPROPERTY('EngineEdition') AS EngineEdition;


/*===========================================================================
  2. SQL SERVER UPTIME
===========================================================================*/

PRINT '--------------------------------------------------------------';
PRINT '2. SQL SERVER UPTIME';
PRINT '--------------------------------------------------------------';

DECLARE @sql_start_time DATETIME;

SELECT
    @sql_start_time = sqlserver_start_time
FROM sys.dm_os_sys_info;

SELECT
    @sql_start_time AS SQLServerStartTime,
    DATEDIFF(DAY, @sql_start_time, GETDATE()) AS UptimeDays,
    DATEDIFF(HOUR, @sql_start_time, GETDATE()) % 24 AS UptimeHours;


/*===========================================================================
  3. DATABASE STATUS
===========================================================================*/

PRINT '--------------------------------------------------------------';
PRINT '3. DATABASE STATUS';
PRINT '--------------------------------------------------------------';

SELECT
    d.name AS DatabaseName,
    d.state_desc AS DatabaseState,
    d.user_access_desc AS UserAccess,
    d.recovery_model_desc AS RecoveryModel,
    d.is_read_only AS IsReadOnly
FROM sys.databases AS d
ORDER BY d.name;


/*===========================================================================
  4. DATABASES NOT ONLINE
===========================================================================*/

PRINT '--------------------------------------------------------------';
PRINT '4. DATABASES NOT ONLINE';
PRINT '--------------------------------------------------------------';

IF EXISTS
(
    SELECT 1
    FROM sys.databases
    WHERE state_desc <> 'ONLINE'
)
BEGIN

    SELECT
        name AS DatabaseName,
        state_desc AS DatabaseState,
        recovery_model_desc AS RecoveryModel
    FROM sys.databases
    WHERE state_desc <> 'ONLINE';

END
ELSE
BEGIN

    PRINT 'PASS: All databases are ONLINE.';

END;


/*===========================================================================
  5. DATABASE SIZE
===========================================================================*/

PRINT '--------------------------------------------------------------';
PRINT '5. DATABASE SIZE';
PRINT '--------------------------------------------------------------';

SELECT
    DB_NAME(mf.database_id) AS DatabaseName,
    SUM(mf.size) * 8.0 / 1024 AS TotalSizeMB,
    SUM(mf.size) * 8.0 / 1024 / 1024 AS TotalSizeGB
FROM sys.master_files AS mf
GROUP BY mf.database_id
ORDER BY TotalSizeGB DESC;


/*===========================================================================
  6. DATABASE FILE INFORMATION
===========================================================================*/

PRINT '--------------------------------------------------------------';
PRINT '6. DATABASE FILE INFORMATION';
PRINT '--------------------------------------------------------------';

SELECT
    DB_NAME(mf.database_id) AS DatabaseName,
    mf.type_desc AS FileType,
    mf.name AS LogicalFileName,
    mf.physical_name AS PhysicalFileName,
    mf.size * 8.0 / 1024 AS SizeMB,
    CASE
        WHEN mf.max_size = -1 THEN 'UNLIMITED'
        ELSE CONVERT(varchar(30), mf.max_size * 8.0 / 1024)
    END AS MaxSizeMB,
    mf.growth,
    CASE
        WHEN mf.is_percent_growth = 1 THEN 'PERCENT'
        ELSE 'MB'
    END AS GrowthType
FROM sys.master_files AS mf
ORDER BY DatabaseName, FileType;


/*===========================================================================
  7. BACKUP STATUS
===========================================================================*/

PRINT '--------------------------------------------------------------';
PRINT '7. BACKUP STATUS - LAST FULL / LOG BACKUP';
PRINT '--------------------------------------------------------------';

SELECT
    d.name AS DatabaseName,

    MAX(
        CASE
            WHEN bs.type = 'D'
            THEN bs.backup_finish_date
        END
    ) AS LastFullBackup,

    MAX(
        CASE
            WHEN bs.type = 'L'
            THEN bs.backup_finish_date
        END
    ) AS LastLogBackup

FROM sys.databases AS d

LEFT JOIN msdb.dbo.backupset AS bs
    ON d.name = bs.database_name

GROUP BY d.name
ORDER BY d.name;


/*===========================================================================
  8. DATABASES WITHOUT RECENT FULL BACKUP
===========================================================================*/

PRINT '--------------------------------------------------------------';
PRINT '8. DATABASES WITHOUT RECENT FULL BACKUP';
PRINT '--------------------------------------------------------------';

SELECT
    d.name AS DatabaseName,
    MAX(bs.backup_finish_date) AS LastFullBackup
FROM sys.databases AS d

LEFT JOIN msdb.dbo.backupset AS bs
    ON d.name = bs.database_name
    AND bs.type = 'D'

WHERE d.name NOT IN ('tempdb')

GROUP BY d.name

HAVING
    MAX(bs.backup_finish_date) IS NULL
    OR MAX(bs.backup_finish_date) < DATEADD(DAY, -1, GETDATE())

ORDER BY LastFullBackup;


/*===========================================================================
  9. FAILED SQL AGENT JOBS
===========================================================================*/

PRINT '--------------------------------------------------------------';
PRINT '9. FAILED SQL AGENT JOBS';
PRINT '--------------------------------------------------------------';

SELECT TOP (20)

    j.name AS JobName,
    msdb.dbo.agent_datetime(h.run_date, h.run_time) AS LastRunDateTime,
    h.run_status,
    h.message

FROM msdb.dbo.sysjobs AS j

INNER JOIN msdb.dbo.sysjobhistory AS h
    ON j.job_id = h.job_id

WHERE h.instance_id IN
(
    SELECT MAX(h2.instance_id)
    FROM msdb.dbo.sysjobhistory AS h2
    WHERE h2.job_id = h.job_id
)

AND h.run_status = 0

ORDER BY LastRunDateTime DESC;


/*===========================================================================
  10. BLOCKING SESSIONS
===========================================================================*/

PRINT '--------------------------------------------------------------';
PRINT '10. CURRENT BLOCKING SESSIONS';
PRINT '--------------------------------------------------------------';

SELECT

    r.session_id AS BlockedSessionID,
    r.blocking_session_id AS BlockingSessionID,
    DB_NAME(r.database_id) AS DatabaseName,
    r.status,
    r.wait_type,
    r.wait_time,
    r.wait_resource,
    r.command,

    s.login_name,
    s.host_name,
    s.program_name,

    r.start_time,

    SUBSTRING
    (
        t.text,
        (r.statement_start_offset / 2) + 1,
        (
            (
                CASE r.statement_end_offset
                    WHEN -1 THEN DATALENGTH(t.text)
                    ELSE r.statement_end_offset
                END
                - r.statement_start_offset
            ) / 2
        ) + 1
    ) AS RunningStatement

FROM sys.dm_exec_requests AS r

INNER JOIN sys.dm_exec_sessions AS s
    ON r.session_id = s.session_id

CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t

WHERE r.blocking_session_id <> 0

ORDER BY r.wait_time DESC;


/*===========================================================================
  11. LONG RUNNING REQUESTS
===========================================================================*/

PRINT '--------------------------------------------------------------';
PRINT '11. LONG RUNNING REQUESTS';
PRINT '--------------------------------------------------------------';

SELECT

    r.session_id,
    DB_NAME(r.database_id) AS DatabaseName,
    r.status,
    r.command,
    r.cpu_time,
    r.total_elapsed_time / 1000.0 AS ElapsedSeconds,
    r.reads,
    r.writes,
    r.logical_reads,
    r.wait_type,
    r.wait_time,

    s.login_name,
    s.host_name,
    s.program_name,

    t.text AS SQLText

FROM sys.dm_exec_requests AS r

INNER JOIN sys.dm_exec_sessions AS s
    ON r.session_id = s.session_id

CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t

WHERE r.session_id <> @@SPID
  AND r.total_elapsed_time >= 300000

ORDER BY r.total_elapsed_time DESC;


/*===========================================================================
  12. TEMPDB INFORMATION
===========================================================================*/

PRINT '--------------------------------------------------------------';
PRINT '12. TEMPDB INFORMATION';
PRINT '--------------------------------------------------------------';

SELECT

    DB_NAME(mf.database_id) AS DatabaseName,
    mf.name AS LogicalFileName,
    mf.type_desc AS FileType,
    mf.size * 8.0 / 1024 AS SizeMB,
    mf.growth,
    CASE
        WHEN mf.is_percent_growth = 1
        THEN 'PERCENT'
        ELSE 'MB'
    END AS GrowthType,
    mf.physical_name

FROM tempdb.sys.database_files AS mf

ORDER BY mf.type_desc, mf.name;


/*===========================================================================
  13. TEMPDB SPACE USAGE
===========================================================================*/

PRINT '--------------------------------------------------------------';
PRINT '13. TEMPDB SPACE USAGE';
PRINT '--------------------------------------------------------------';

SELECT

    SUM(user_object_reserved_page_count) * 8.0 / 1024
        AS UserObjectMB,

    SUM(internal_object_reserved_page_count) * 8.0 / 1024
        AS InternalObjectMB,

    SUM(version_store_reserved_page_count) * 8.0 / 1024
        AS VersionStoreMB,

    SUM(unallocated_extent_page_count) * 8.0 / 1024
        AS FreeSpaceMB

FROM tempdb.sys.dm_db_file_space_usage;


/*===========================================================================
  14. MEMORY INFORMATION
===========================================================================*/

PRINT '--------------------------------------------------------------';
PRINT '14. MEMORY INFORMATION';
PRINT '--------------------------------------------------------------';

SELECT

    total_physical_memory_kb / 1024 AS TotalPhysicalMemoryMB,
    available_physical_memory_kb / 1024 AS AvailablePhysicalMemoryMB,
    system_memory_state_desc AS SystemMemoryState

FROM sys.dm_os_sys_memory;


/*===========================================================================
  15. SQL SERVER MEMORY CONFIGURATION
===========================================================================*/

PRINT '--------------------------------------------------------------';
PRINT '15. SQL SERVER MEMORY CONFIGURATION';
PRINT '--------------------------------------------------------------';

SELECT

    name AS ConfigurationName,
    value_in_use AS ValueInUse,
    description

FROM sys.configurations

WHERE name IN
(
    'min server memory (MB)',
    'max server memory (MB)'
)

ORDER BY name;


/*===========================================================================
  16. CPU INFORMATION
===========================================================================*/

PRINT '--------------------------------------------------------------';
PRINT '16. CPU INFORMATION';
PRINT '--------------------------------------------------------------';

SELECT

    cpu_count AS LogicalCPUCount,
    hyperthread_ratio AS HyperthreadRatio,
    scheduler_count AS SchedulerCount,
    physical_memory_kb / 1024 AS PhysicalMemoryMB,
    sqlserver_start_time

FROM sys.dm_os_sys_info;


/*===========================================================================
  17. WAIT STATISTICS - TOP WAITS
===========================================================================*/

PRINT '--------------------------------------------------------------';
PRINT '17. TOP SQL SERVER WAIT STATISTICS';
PRINT '--------------------------------------------------------------';

SELECT TOP (15)

    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    signal_wait_time_ms,
    wait_time_ms - signal_wait_time_ms AS ResourceWaitTimeMs

FROM sys.dm_os_wait_stats

WHERE wait_type NOT IN
(
    'SLEEP_TASK',
    'BROKER_TASK_STOP',
    'BROKER_TO_FLUSH',
    'SQLTRACE_BUFFER_FLUSH',
    'CLR_AUTO_EVENT',
    'CLR_MANUAL_EVENT',
    'LAZYWRITER_SLEEP',
    'REQUEST_FOR_DEADLOCK_SEARCH',
    'XE_TIMER_EVENT',
    'XE_DISPATCHER_WAIT',
    'FT_IFTS_SCHEDULER_IDLE_WAIT',
    'BROKER_EVENTHANDLER',
    'DIRTY_PAGE_POLL',
    'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
    'SP_SERVER_DIAGNOSTICS_SLEEP'
)

ORDER BY wait_time_ms DESC;


/*===========================================================================
  18. DATABASE RECOVERY MODEL SUMMARY
===========================================================================*/

PRINT '--------------------------------------------------------------';
PRINT '18. RECOVERY MODEL SUMMARY';
PRINT '--------------------------------------------------------------';

SELECT

    recovery_model_desc AS RecoveryModel,
    COUNT(*) AS DatabaseCount

FROM sys.databases

GROUP BY recovery_model_desc

ORDER BY recovery_model_desc;


/*===========================================================================
  19. READ-ONLY DATABASE CHECK
===========================================================================*/

PRINT '--------------------------------------------------------------';
PRINT '19. READ-ONLY DATABASES';
PRINT '--------------------------------------------------------------';

SELECT

    name AS DatabaseName,
    state_desc AS DatabaseState,
    user_access_desc AS UserAccess

FROM sys.databases

WHERE is_read_only = 1;


/*===========================================================================
  20. DATABASE AUTO GROWTH CONFIGURATION
===========================================================================*/

PRINT '--------------------------------------------------------------';
PRINT '20. AUTO GROWTH CONFIGURATION';
PRINT '--------------------------------------------------------------';

SELECT

    DB_NAME(database_id) AS DatabaseName,
    name AS LogicalFileName,
    type_desc AS FileType,
    growth,
    CASE
        WHEN is_percent_growth = 1
        THEN 'PERCENT'
        ELSE 'MB'
    END AS GrowthType

FROM sys.master_files

ORDER BY DatabaseName, FileType;


/*===========================================================================
  21. BASIC HEALTH SUMMARY
===========================================================================*/

PRINT '--------------------------------------------------------------';
PRINT '21. BASIC HEALTH SUMMARY';
PRINT '--------------------------------------------------------------';

DECLARE @OfflineDB INT;
DECLARE @RecoveringDB INT;
DECLARE @SuspectDB INT;

SELECT
    @OfflineDB =
        COUNT(*)
FROM sys.databases
WHERE state_desc = 'OFFLINE';

SELECT
    @RecoveringDB =
        COUNT(*)
FROM sys.databases
WHERE state_desc IN
(
    'RECOVERING',
    'RECOVERY_PENDING'
);

SELECT
    @SuspectDB =
        COUNT(*)
FROM sys.databases
WHERE state_desc IN
(
    'SUSPECT',
    'EMERGENCY'
);

SELECT

    @OfflineDB AS OfflineDatabases,
    @RecoveringDB AS RecoveringDatabases,
    @SuspectDB AS SuspectOrEmergencyDatabases,

    CASE
        WHEN @SuspectDB > 0
            THEN 'CRITICAL - SUSPECT/EMERGENCY DATABASE FOUND'

        WHEN @RecoveringDB > 0
            THEN 'WARNING - DATABASE RECOVERY ISSUE'

        WHEN @OfflineDB > 0
            THEN 'WARNING - OFFLINE DATABASE FOUND'

        ELSE 'PASS - NO DATABASE STATE ISSUE DETECTED'
    END AS OverallDatabaseStatus;


/*===========================================================================
  END OF HEALTH CHECK
===========================================================================*/

PRINT '';
PRINT '==============================================================';
PRINT '        SQL SERVER HEALTH CHECK COMPLETED';
PRINT '==============================================================';

SET NOCOUNT OFF;
