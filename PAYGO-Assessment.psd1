@{
    ModuleVersion = '1.0.0'
    GUID = '440abcb2-4698-4b33-9e6c-982cd5734c31'
    Author = 'Oliver Hahn'
    Description = 'PAYGO Assessment'
	# Company or vendor of this module
	CompanyName = 'Microsoft Corporation'
	# Copyright statement for this module
	Copyright = '2024'	
	PowerShellVersion = '3.0'
	# Name of the Windows PowerShell host required by this module
	PowerShellHostName = ''
	# Minimum version of the Windows PowerShell host required by this module
	PowerShellHostVersion = '3.0'
	# Minimum version of the .NET Framework required by this module
	DotNetFrameworkVersion = '4.5'
	# Minimum version of the common language runtime (CLR) required by this module
	CLRVersion = '4.0'
	# Processor architecture (None, X86, Amd64, IA64) required by this module
	ProcessorArchitecture = ''
	# Modules that must be imported into the global environment prior to importing this module
	RequiredModules = @()
	# Assemblies that must be loaded prior to importing this module
	RequiredAssemblies = @()
	# Script files (.ps1) that are run in the caller's environment prior to importing this module
	ScriptsToProcess = @(
		'.\Functions\Init-Module.ps1';
	)
	# Type files (.ps1xml) to be loaded when importing this module
	TypesToProcess = @()
	# Format files (.ps1xml) to be loaded when importing this module
	FormatsToProcess = @()
	# Modules to import as nested modules of the module specified in ModuleToProcess
	NestedModules = @(
		'.\Functions\Init-Module.ps1';
		'.\Functions\Deploy-PAYGO-Assessment.ps1';
		'.\Functions\Collect-PAYGO-AssessmentResults.ps1';
		'.\Functions\Cleanup-PAYGO-Assessment.ps1';
	)
	# Functions to export from this module
	FunctionsToExport = '*'
	# Cmdlets to export from this module
	CmdletsToExport = '*'
	# Aliases to export from this module
	AliasesToExport = '*'
	# List of all modules packaged with this module
	ModuleList = @()
	# List of all files packaged with this module
	FileList = @()
	# Private data to pass to the module specified in ModuleToProcess
	PrivateData = ''	
}
