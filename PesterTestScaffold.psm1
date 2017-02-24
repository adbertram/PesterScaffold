function Find-FunctionReference
{
	<#
	.SYNOPSIS
		This function parses an existing function and attempts to find all of the command references therein. Once a command
		reference is found, it will then attempt to parse all parameters passed to that command.
		
	.EXAMPLE
		PS> Get-Content Function:\Get-Something

		    [CmdletBinding()]
		    param ()

		    write-log -Message 'value1' -Source 'value2'
		    Test-path 'valbyposition'

		    $splatParams = @{
		        'splatparam1' = 'splatval1'
		        'splatparam2' = 'splatval2'
		    }

    		Add-Content @splatParams
	
		PS> Find-FunctionReference -FunctionName Get-Something
	
		ParentFunction ChildFunction ChildFunctionParameter
		-------------- ------------- ----------------------
		Get-Something  write-log     {Message, Source}
		Get-Something  Test-path     {Path}
		Get-Something  Add-Content   {splatparam2, splatparam1}
		
	.PARAMETER FunctionName
		A mandatory string parameter representing the name of the function you'd like to find all function references in.
	#>
	[OutputType([pscustomobject])]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string[]]$FunctionName
	)
	$ErrorActionPreference = 'Stop'
	@($FunctionName).foreach({
			try
			{
				$funcName = $_
				if (-not ($Function = Get-Command -Name $funcName))
				{
					throw "The function [$($funcName)] could not be found."
				}
				
				if ($Function.CommandType -eq 'Cmdlet')
				{
					throw "The function [$($funcName)] is a cmdlet and cannot be parsed."
				}
				
				$ast = $Function.ScriptBlock.Ast
				
				## TODO: ADB - Figure out how to get param sent to Do-Something
				## ie Get-Something -Param 'value' | Do-Something
				
				@($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)).foreach({
						
						$childName = $_.CommandElements[0].Value
						
						$output = [Ordered]@{
							'ParentFunction' = $funcName
							'ChildFunction' = $childName
							'ChildFunctionParameter' = $null
						}
						
						if ($params = Get-CommandParameter -ParentCommand $Function -Command $_)
						{
							$output.ChildFunctionParameter = $params
						}
						
						[pscustomobject]$output
					})
			}
			catch
			{
				$PSCmdlet.ThrowTerminatingError($_)
			}
		})
}

function Get-CommandParameter
{
	<#
	.SYNOPSIS
		This function discovers and parses all parameteres from an existing function. This function finds each command
		reference in an existing function and attempts to parse what parameters are being passed to it. It will discover
		all parameters passed by name, position and splatting. It will NOT discover parameters passed via pipeline binding
		This is not possible at parse time. If will, however, detect if pipeline input if being used with a command
		and simply return PIPELINEINPUT to indicate this needs to be manually intervened.
	
		This function is a helper function for Find-FunctionReference.
		
	.EXAMPLE
		PS> Get-Content Function:\Get-Something

		    [CmdletBinding()]
		    param ()

		    write-log -Message 'value1' -Source 'value2'
		    Test-path 'valbyposition'

		    $splatParams = @{
		        'splatparam1' = 'splatval1'
		        'splatparam2' = 'splatval2'
		    }

    		Add-Content @splatParams
	
		PS> $command = Get-Command 'Get-Something'
		PS> $commands = ($command.scriptblock.ast).FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)
		PS> Get-CommandParameter -Command $commands[0] -ParentCommand $command
	
		Name                           Value
		----                           -----
		Message                        value1
		Source                         value2
	
	.EXAMPLE

		PS> Get-Content Function:\Get-Something

		    [CmdletBinding()]
		    param ()

		    write-log -Message 'value1' -Source 'value2'
		    Test-path 'valbyposition'

		    $splatParams = @{
		        'splatparam1' = 'splatval1'
		        'splatparam2' = 'splatval2'
		    }

    		Add-Content @splatParams
	
		PS> $command = Get-Command 'Get-Something'
		PS> $commands = ($command.scriptblock.ast).FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)
		PS> Get-CommandParameter -Command $commands[1] -ParentCommand $command
	
		Name                           Value
		----                           -----
		Path                           valbyposition
		
	.PARAMETER Command
		A mandatory CommandAst object representing the command to look for commands with parameters.
	
	.PARAMETER ParentCommand
		An optional, most likely CommandInfo object, representing the command that called Command. This is only mandatory
		when the command has any refernce to another command using splatted parameters.
	#>
	[OutputType([hashtable])]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory, ValueFromPipeline)]
		[ValidateNotNullOrEmpty()]
		[System.Management.Automation.Language.CommandAst]$Command,
		
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[object]$ParentCommand
	)
	$ErrorActionPreference = 'Stop'
	try
	{
		## When the pipeline is used to pass parameters to commands, it does not show up as a StaticParamater and must
		## be processed differently.
		$params = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($Command)
		
		$outputHt = @{ }
		if (($Command.Parent.Extent.Text -match '\|') -and ($params.BindingExceptions.Count -eq 0) -and ($params.BoundParameters.Count -eq 0))
		{
			$outputHt['PipelineInput'] = 'PipelineInput'

		} 
		elseif ($params) 
		{
			$commandName = $Command.CommandElements[0].Value
			$commandInfo = Get-Command -Name $commandName -ErrorAction Ignore
			
			@($params).foreach({
					## Merge both exceptions and bound parameters together. BindingExceptions sometimes contains
					## splat parameters. These are not problems but need to be processed differently.
					$bParams = $_.BindingExceptions + $_.BoundParameters
					@($bParams.GetEnumerator()).where({ $_.Key -notin 'like', 'eq', 'match', 'and' }).foreach({
							if ($_.Key -match '^@')
							{
								$paramName = $_.Value -replace "'|`""
								$paramValue = $_.Value -replace "'|`""
							}
							else
							{
								$paramName = $_.Key -replace "'|`""
								$paramValue = $_.Value.Value -replace "'|`""
							}
							
							$paramBindingType = Get-ParameterBindingType -Parameter $_
							
							switch ($paramBindingType)
							{
								'Position' {
									if (-not $commandInfo)
									{
										$errMessage = @"
Unable to find parameter names for referenced function [$($commandName)]. This command uses positional parameters and 
in order to discover the parameter names, this command must be able to be loaded into your current session."
"@
										throw $errMessage
									}
									Write-Verbose -Message "Parameter [$($paramName)] for function [$($commandName)] is bound by position."
									$outputHt[(Get-CommandParameterMetadata -Command $commandInfo -Position $paramName).Name] = $paramValue
								}
								'Splat' {
									if (-not $PSBoundParameters.ContainsKey('ParentCommand'))
									{
										$errMessage = @"
"Splatted parameters used for command and ParentFunction not used. Since the parameters used for splatting are defined
in a hashtable somewhere else in the script/function, the calling function command must be passed to this function.
"@
										throw $errMessage
									}
									Write-Verbose -Message "Parameter [$($paramName)] for function [$($commandName)] is bound by splatting."
									@(Find-SplattedParameter -Command $ParentCommand).foreach({
											$outputHt[$_.Name] = $_.Value
										})
								}
								'Name' {
									Write-Verbose -Message "Parameter [$($paramName)] for function [$($commandName)] is bound by name."
									
									$outputHt[$paramName] = $paramValue
								}
								default
								{
									throw "Unrecognized binding type: [$($_)] found."
								}
							}
						})
				})
		}
		$outputHt
	}
	catch
	{
		Write-Error "$($_.Exception.Message) - Line Number: $($_.InvocationInfo.ScriptLineNumber)"
	}
}

function Get-ParameterBindingType
{
	<#
	.SYNOPSIS
		A helper function for Get-CommandParameter to determine how parameters were bound to a command. This is used
		to determine how to parse out parameters from a command.
		
	.EXAMPLE
		PS> Get-Content Function:\Get-Something

		    [CmdletBinding()]
		    param ()

		    write-log -Message 'value1' -Source 'value2'
		    Test-path 'valbyposition'

		    $splatParams = @{
		        'splatparam1' = 'splatval1'
		        'splatparam2' = 'splatval2'
		    }

    		Add-Content @splatParams
	
		PS> $command = Get-Command 'Get-Something'
		PS> $commands = ($command.scriptblock.ast).FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)
		PS> $param = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($commands[0])
		PS> $parambind = $param.BoundParameters.GetEnumerator()[0]
		PS> Get-ParameterBindingType -Parameter $parambind
		Name
	
	.PARAMETER Parameter
		A mandatory parameter representing a CommandAst.
	#>
	[OutputType([string])]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[object]$Parameter
	)
	
	try
	{
		if (($Parameter.Key -is [int]) -and ($Parameter.Value.Value -notmatch '^@'))
		{
			'Position'
		}
		elseif ($Parameter.Value.Value -match '@')
		{
			'Splat'
		}
		else
		{
			'Name'
		}
	}
	catch
	{
		$PSCmdlet.ThrowTerminatingError($_)
	}
}

function Find-SplattedParameter
{
	<#
	.SYNOPSIS
		This is a helper function for Get-CommandParameter that breaks apart a splatted set of parameters (@parameters) 
		detected inside of a command into individual objects of pscustomobject.
		
	.EXAMPLE
		PS> Get-Content Function:\Get-Something

		    [CmdletBinding()]
		    param ()

		    write-log -Message 'value1' -Source 'value2'
		    Test-path 'valbyposition'

		    $splatParams = @{
		        'splatparam1' = 'splatval1'
		        'splatparam2' = 'splatval2'
		    }

    		Add-Content @splatParams
	
		PS> Find-SplattedParameter -Command (Get-Command Get-Something)
	
		Name        Value
		----        -----
		splatparam1 splatval1
		splatparam2 splatval2
		
	.PARAMETER Command
		A mandatory parameter representing a function or cmdlet command. This can be found by using Get-Command.
	
	.PARAMETER ParameterName
		An optional parameter representing a specific parameter to return.
	#>
	[OutputType([pscustomobject])]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[object]$Command,
		
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[ValidatePattern('^@')]
		[string]$ParameterName
	)
	begin
	{
		$ErrorActionPreference = 'Stop'
	}
	process
	{
		try
		{
			$ast = $Command.ScriptBlock.Ast
			$varExpressions = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)
			
			$whereConditions = @('$_.Splatted')
			if ($PSBoundParameters.ContainsKey('ParameterName'))
			{
				$whereConditions += '($_.variablepath.UserPath -eq $Name)'
			}
			$whereString = $whereConditions -join ' -and '
			$whereFilter = [scriptblock]::Create($whereString)
			
			@($varExpressions).where($whereFilter).foreach({
					$splatVarName = $_.variablepath.UserPath
					$splatVarHt = @($varExpressions).where({ (-not $_.Splatted) -and ($_.variablePath.Userpath -eq $splatVarName) })
					$splatVarHtKvp = $splatVarHt.Parent.Right.Expression.KeyValuePairs
					@($splatVarHtKvp).foreach({
							[pscustomobject]@{
								'Name' = $_.Item1 -replace "'|`"";
								'Value' = $_.Item2 -replace "'|`""
							}
						})
				})
		}
		catch
		{
			Write-Error "$($_.Exception.Message) - Line Number: $($_.InvocationInfo.ScriptLineNumber)"
		}
	}
}

function Get-CommandParameterMetadata
{
	<#
	.SYNOPSIS
		This function is a helper function for Get-CommandParameter. It's purpose is to transform the position property
		in a more useful way. However, it also acts as a way to only return certain necessary properties from a parameter.
	
	.EXAMPLE
		PS> Get-CommandParameterMetadata -Command (Get-Command Get-Something)
		
		Aliases                         : {vb}
		HelpMessage                     :
		IsDynamic                       : False
		IsMandatory                     : False
		Name                            : Verbose
		ParameterType                   : System.Management.Automation.SwitchParameter
		ValueFromPipeline               : False
		ValueFromPipelineByPropertyName : False
		ValueFromRemainingArguments     : False
		Position                        :
		ParameterSetName                : __AllParameterSets
	
		...
		
	.PARAMETER Command
		A mandatory object representing a function or cmdlet. This can be gathered by running Get-Command. This function
		will parse this command, discover all parameters and return a formatted output.
	
	.PARAMETER Position
		An optional integer representing a single parameter by position. Use this if you only want to return a single
		parameter by position.
	#>
	[OutputType([pscustomobject])]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[object]$Command,
		
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[int]$Position
	)
	begin
	{
		$ErrorActionPreference = 'Stop'
	}
	process
	{
		try
		{
			$properties = @(
				'Aliases',
				'HelpMessage',
				'IsDynamic',
				'IsMandatory',
				'Name',
				'ParameterType',
				'ValueFromPipeline',
				'ValueFromPipelineByPropertyName',
				'ValuefromRemainingarguments',
				@{
					Name = 'Position'; e = {
						if ($_.Position -lt 0)
						{
							$null
						}
						else
						{
							$_.Position
						}
					}
				}
			)
			
			$whereFilter = { $_ }
			if ($PSBoundParameters.ContainsKey('Position'))
			{
				$whereFilter = { $_.Position -eq [int]$Position }
			}
			
			$Command.parametersets.foreach({
					$psetName = $_.Name
					$properties += @{ n = 'ParameterSetName'; e = { $psetName } }
					@($_.Parameters).where($whereFilter) | Select-Object -Property $properties
				})
		}
		catch
		{
			Write-Error "$($_.Exception.Message) - Line Number: $($_.InvocationInfo.ScriptLineNumber)"
		}
	}
}

function New-MockTemplate
{
	<#
	.SYNOPSIS
		This function combines each common mock parameter (MockWith,ParameterFilter and the CommandName) and creates
		a mock template from them.
		
	.EXAMPLE
		PS> New-MockTemplate -CommandName Get-Something -MockWith {return 'something'} -ParameterFilter {$Object -eq $true}
	
			mock 'Get-Something'{
         		return 'something'
			} -ParameterFilter { $Object -eq $true }
	
	.PARAMETER CommandName
		A mandatory string representing the name of the command you intend to mock.
	
	.PARAMETER MockWith
		An optional scriptblock representing the code to execute rather than tha actual code.
	
	.PARAMETER ParameterFilter
		An optional scriptblock representing the parameter filter to trigger the mock.
	
	#>
	[OutputType([string])]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$CommandName,
		
		[Parameter()]
		[string]$MockWith,
		
		[Parameter()]
		[string]$ParameterFilter
	)
	begin
	{
		$ErrorActionPreference = 'Stop'
	}
	process
	{
		try
		{	
			if ($ParameterFilter)
			{
				$ParameterFilter = "-ParameterFilter { $ParameterFilter }"
			}
			
			@'
mock '{0}' {{
	{1}
}} {2}
'@ -f $CommandName,$MockWith,$ParameterFilter

		}
		catch
		{
			Write-Error "$($_.Exception.Message) - Line Number: $($_.InvocationInfo.ScriptLineNumber)"
		}
	}
}

function New-MockParameterFilterTemplate
{
	<#
	.SYNOPSIS
		This function returns a parameter filter scriptblock template to be used with a mock.
		
	.DESCRIPTION
		This function takes a set of key/value pairs in the Parameter parameter representing parameters used for a function
		to be mocked. It then combines them to create a parameter filter capable of being used as the -ParameterFilter
		parameter on mock.
	
	.EXAMPLE
		PS> New-MockParameterFilterTemplate -Parameter @{Name='val1';Name2='val2'}
	
		Name -eq 'val1' -and Name2 -eq 'val2'
		
	.PARAMETER Parameter
		A hashtable of key/value pairs represeting each parameter name and value.
	#>
	[OutputType([scriptblock])]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[hashtable]$Parameter
	)
	begin
	{
		$ErrorActionPreference = 'Stop'
	}
	process
	{
		try
		{
			[array]$arr = $Parameter.Getenumerator().foreach({
					if (-not $_.Value) {
						'{0}{1}' -f '$',$_.Name
					} else {
						"`${0} -eq '{1}'" -f $_.Name,$_.Value
					}
				})
			$paramfilter = $arr -join ' -and '
			[scriptblock]::Create($paramfilter)
		}
		catch
		{
			Write-Error "$($_.Exception.Message) - Line Number: $($_.InvocationInfo.ScriptLineNumber)"
		}
	}
}

function New-DescribeBlockTemplate
{
	<#
	.SYNOPSIS
		This function creates a string output representing a Pester describe block template based on the contents
		of an existing function.
		
	.DESCRIPTION
		Use this function to automate the creation of Pester unit tests from existing functions. This function returns
		a string containing a describe block template along with all mocks with parameter filters needed as a starting
		point in developing unit tests for a function.
	
	.EXAMPLE
		PS> Get-Content Function:\Get-Something

		    [CmdletBinding()]
		    param ()

		    write-log -Message 'value1' -Source 'value2'
		    Test-path 'valbyposition'

		    $splatParams = @{
		        'splatparam1' = 'splatval1'
		        'splatparam2' = 'splatval2'
		    }

    		Add-Content @splatParams

		PS> New-DescribeBlockTemplate -FunctionName Get-Something
	
			describe 'Get-Something' {
				mock 'write-log' -ParameterFilter { Message -eq 'value1' -and Source -eq 'value2' }
				mock 'Test-path' -ParameterFilter { Path -eq 'valbyposition' }
				mock 'Add-Content' -ParameterFilter { splatparam2 -eq 'splatval2' -and splatparam1 -eq 'splatval1' }
			}
	
	.PARAMETER FunctionName
		The name of the function to create the describe block for. This function must be available in a module or loaded
		into your session before running.
	
	#>
	[OutputType([string])]
	[CmdletBinding()]
	param
	(
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$FunctionName,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string[]]$ExcludeCommandMock = @('Write-Verbose','Write-Host')
	)
	begin
	{
		$ErrorActionPreference = 'Stop'
	}
	process
	{
		try
		{
			if ($funcRefs = @(Find-FunctionReference -FunctionName $FunctionName).where({$_.ChildFunction -notin $ExcludeCommandMock}))
			{
				@($funcRefs).foreach({
					$params = @{
						CommandName = $_.ChildFunction
						MockWith = $null
					}
					if ($_.ChildFunctionParameter)
					{
						$params.ParameterFilter = New-MockParameterFilterTemplate $_.ChildFunctionParameter
					} else {
						$params.ParameterFilter = $null
					}
					$template = New-MockTemplate @params
					$template + "`n"
				})
			}
		}
		catch
		{
			$PSCmdlet.ThrowTerminatingError($_)
		}
	}
}