$ErrorActionPreference = 'Stop'

$raiz = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$projetoWeb = 'src/GestaoOrcamentos.Web/GestaoOrcamentos.Web.csproj'
$nomeBanco = 'GestaoOrcamentos_Benchmark_' + [guid]::NewGuid().ToString('N')
$variavelConexao = 'ConnectionStrings__GestaoOrcamentos'
$conexaoAnterior = [Environment]::GetEnvironmentVariable($variavelConexao, 'Process')
$conexaoBanco = "Server=(localdb)\MSSQLLocalDB;Database=$nomeBanco;Integrated Security=True;TrustServerCertificate=True;Connect Timeout=30"
$conexaoMaster = "Server=(localdb)\MSSQLLocalDB;Database=master;Integrated Security=True;TrustServerCertificate=True;Connect Timeout=30"
$arquivoMassa = Join-Path $PSScriptRoot 'medir-indice-vencidos.sql'
$arquivoPlanoSemIndice = Join-Path $PSScriptRoot 'plano-sem-indice.sqlplan'
$arquivoPlanoComIndice = Join-Path $PSScriptRoot 'plano-com-indice.sqlplan'
$erroExecucao = $null

function Invoke-SqlNonQuery([string]$connectionString, [string]$commandText) {
    $connection = [System.Data.SqlClient.SqlConnection]::new($connectionString)
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        try {
            $command.CommandTimeout = 120
            $command.CommandText = $commandText
            [void]$command.ExecuteNonQuery()
        }
        finally {
            $command.Dispose()
        }
    }
    finally {
        $connection.Dispose()
    }
}

function Get-Metric([System.Xml.XmlNode]$node, [string]$attribute) {
    if ($null -eq $node -or -not $node.Attributes[$attribute]) {
        return 0
    }

    return [long]$node.Attributes[$attribute].Value
}

function Invoke-Medicao([string]$connectionString, [string]$nome, [string]$arquivoPlano, [string]$consulta) {
    $connection = [System.Data.SqlClient.SqlConnection]::new($connectionString)
    $mensagens = [System.Collections.Generic.List[string]]::new()
    $handler = [System.Data.SqlClient.SqlInfoMessageEventHandler] {
        param($sender, $eventArgs)
        $mensagens.Add($eventArgs.Message)
    }

    $ids = [System.Collections.Generic.List[int]]::new()
    $plano = $null
    $connection.add_InfoMessage($handler)

    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        try {
            $command.CommandTimeout = 120
            $command.CommandText = @"
SET NOCOUNT ON;
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
SET STATISTICS XML ON;
$consulta
SET STATISTICS XML OFF;
SET STATISTICS TIME OFF;
SET STATISTICS IO OFF;
"@

            $reader = $command.ExecuteReader()
            try {
                do {
                    if ($reader.FieldCount -eq 0) {
                        continue
                    }

                    $tipo = $reader.GetDataTypeName(0)
                    while ($reader.Read()) {
                        if ($tipo -eq 'int') {
                            $ids.Add($reader.GetInt32(0))
                        }
                        elseif ($tipo -eq 'xml' -or $tipo -eq 'nvarchar') {
                            $valor = [string]$reader.GetValue(0)
                            if ($valor.TrimStart().StartsWith('<ShowPlanXML')) {
                                $plano = $valor
                            }
                        }
                    }
                } while ($reader.NextResult())
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $command.Dispose()
        }
    }
    finally {
        $connection.remove_InfoMessage($handler)
        $connection.Dispose()
    }

    if ([string]::IsNullOrWhiteSpace($plano)) {
        throw "O SQL Server não retornou o plano real da execução '$nome'."
    }

    [System.IO.File]::WriteAllText($arquivoPlano, $plano, [System.Text.UTF8Encoding]::new($false))
    [xml]$xmlPlano = $plano
    $ns = [System.Xml.XmlNamespaceManager]::new($xmlPlano.NameTable)
    $ns.AddNamespace('sp', 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    $operadorTabela = $xmlPlano.SelectSingleNode(
        '//sp:RelOp[sp:IndexScan/sp:Object[contains(@Table, "Orcamentos")] or sp:TableScan/sp:Object[contains(@Table, "Orcamentos")]]',
        $ns)
    if ($null -eq $operadorTabela) {
        throw "Não foi possível identificar a leitura de dbo.Orcamentos no plano '$nome'."
    }

    $execucao = $operadorTabela.SelectSingleNode('./sp:RunTimeInformation/sp:RunTimeCountersPerThread', $ns)
    $tempo = $xmlPlano.SelectSingleNode('//sp:QueryTimeStats', $ns)
    $leiturasLogicas = Get-Metric $execucao 'ActualLogicalReads'
    $linhasLidas = Get-Metric $execucao 'ActualRowsRead'
    $cpuMs = Get-Metric $tempo 'CpuTime'
    $decorridoMs = Get-Metric $tempo 'ElapsedTime'
    $tempoDeclarado = $null
    foreach ($mensagem in $mensagens) {
        $capturaTempo = [regex]::Match(
            $mensagem,
            'SQL Server Execution Times:\s*CPU time = (?<cpu>\d+) ms,\s*elapsed time = (?<decorrido>\d+) ms\.')
        if ($capturaTempo.Success) {
            $candidato = [pscustomobject]@{
                CpuMs = [long]$capturaTempo.Groups['cpu'].Value
                DecorridoMs = [long]$capturaTempo.Groups['decorrido'].Value
            }
            if ($null -eq $tempoDeclarado -or
                $candidato.DecorridoMs -gt $tempoDeclarado.DecorridoMs -or
                ($candidato.DecorridoMs -eq $tempoDeclarado.DecorridoMs -and $candidato.CpuMs -gt $tempoDeclarado.CpuMs)) {
                $tempoDeclarado = $candidato
            }
        }
    }
    if ($null -ne $tempoDeclarado) {
        $cpuMs = $tempoDeclarado.CpuMs
        $decorridoMs = $tempoDeclarado.DecorridoMs
    }

    Write-Host "`n$nome"
    Write-Host "  Operador: $($operadorTabela.Attributes['PhysicalOp'].Value)"
    Write-Host "  Linhas lidas: $linhasLidas; leituras lógicas: $leiturasLogicas"
    Write-Host "  CPU / decorrido: $cpuMs ms / $decorridoMs ms"
    Write-Host "  Plano real: $arquivoPlano"
    foreach ($mensagem in $mensagens) {
        Write-Host "  $mensagem"
    }

    return [pscustomobject]@{
        Nome = $nome
        IDs = [int[]]$ids.ToArray()
        Operador = $operadorTabela.Attributes['PhysicalOp'].Value
        LinhasLidas = $linhasLidas
        LeiturasLogicas = $leiturasLogicas
        CpuMs = $cpuMs
        DecorridoMs = $decorridoMs
        Plano = $arquivoPlano
        Estatisticas = [string[]]$mensagens.ToArray()
    }
}

Push-Location $raiz
try {
    [Environment]::SetEnvironmentVariable(
        $variavelConexao,
        "Server=(localdb)\MSSQLLocalDB;Database=$nomeBanco;Trusted_Connection=True;TrustServerCertificate=True",
        'Process')

    Write-Host "Criando banco descartável $nomeBanco..."
    $saidaMigracao = dotnet ef database update --project $projetoWeb --startup-project $projetoWeb 2>&1
    if ($LASTEXITCODE -ne 0) {
        $saidaMigracao | ForEach-Object { Write-Host $_ }
        throw 'Não foi possível criar o banco LocalDB temporário com as migrations atuais.'
    }

    $sqlMassa = Get-Content -Raw $arquivoMassa
    Invoke-SqlNonQuery $conexaoBanco $sqlMassa

    $consulta = Get-Content -Raw (Join-Path $PSScriptRoot 'consulta-vencidos.sql')
    $semIndice = Invoke-Medicao $conexaoBanco 'Sem índice' $arquivoPlanoSemIndice $consulta
    if ($semIndice.IDs.Count -ne 2500) {
        throw "Sem índice: esperava 2.500 IDs, mas a consulta retornou $($semIndice.IDs.Count)."
    }

    $idsEsperados = [int[]](1..2500 | ForEach-Object { $_ * 40 })
    $idsSemIndiceOrdenados = [int[]]($semIndice.IDs | Sort-Object)
    if (($idsSemIndiceOrdenados -join ',') -cne ($idsEsperados -join ',')) {
        throw 'Sem índice: os IDs retornados não correspondem aos 2.500 vencimentos anteriores à data de referência.'
    }

    Invoke-SqlNonQuery $conexaoBanco @'
CREATE INDEX IX_Orcamentos_Pendente_Validade ON dbo.Orcamentos (Validade, Id)
WHERE Situacao = 1 AND Validade IS NOT NULL;
'@

    $comIndice = Invoke-Medicao $conexaoBanco 'Com índice filtrado' $arquivoPlanoComIndice $consulta
    if ($comIndice.IDs.Count -ne 2500) {
        throw "Com índice: esperava 2.500 IDs, mas a consulta retornou $($comIndice.IDs.Count)."
    }

    $idsSemIndiceOrdenados = [int[]]($semIndice.IDs | Sort-Object)
    $idsComIndiceOrdenados = [int[]]($comIndice.IDs | Sort-Object)
    if (($idsSemIndiceOrdenados -join ',') -cne ($idsComIndiceOrdenados -join ',')) {
        throw 'Os IDs retornados com e sem o índice são diferentes.'
    }

    Write-Host "`nValidação: 100.000 orçamentos; 5.000 pendentes; 2.500 vencidos."
    Write-Host 'Os mesmos 2.500 IDs foram retornados nos dois casos; validade igual a 16/10/2026 e validade nula não aparecem no alerta.'
}
catch {
    $erroExecucao = $_
    throw
}
finally {
    try {
        Invoke-SqlNonQuery $conexaoMaster "IF DB_ID(N'$nomeBanco') IS NOT NULL BEGIN ALTER DATABASE [$nomeBanco] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$nomeBanco]; END;"
        Write-Host "`nBanco descartável removido: $nomeBanco"
    }
    catch {
        if ($null -eq $erroExecucao) {
            throw
        }

        Write-Warning "Não foi possível remover o banco descartável ${nomeBanco}: $($_.Exception.Message)"
    }
    finally {
        if ($null -eq $conexaoAnterior) {
            [Environment]::SetEnvironmentVariable($variavelConexao, $null, 'Process')
        }
        else {
            [Environment]::SetEnvironmentVariable($variavelConexao, $conexaoAnterior, 'Process')
        }

        Pop-Location
    }
}
