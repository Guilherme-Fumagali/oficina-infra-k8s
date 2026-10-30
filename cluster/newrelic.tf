locals {
  amb        = title(var.ambiente)
  nr_enabled = var.enable_newrelic ? 1 : 0
  nr_email   = var.enable_newrelic && var.alerta_email != "" ? 1 : 0

  runbook_base = "https://github.com/Guilherme-Fumagali/tech-challenge-1/blob/main/docs/runbooks"

  servicos_newrelic = {
    for chave in keys(var.servicos) : chave => {
      app        = "oficina-${chave}-service-${var.ambiente}"
      deployment = "${chave}-service"
      recurso    = "${title(chave)}Service"
    }
  }

  filtro_k8s = "clusterName = '${local.nome}' AND namespaceName = 'oficina'"
}

resource "newrelic_alert_policy" "oficina" {
  count               = local.nr_enabled
  name                = "AWS-Oficina-${local.amb}"
  incident_preference = "PER_CONDITION_AND_TARGET"
}

resource "newrelic_notification_destination" "email" {
  count = local.nr_email

  name = "oficina-api-${var.ambiente}-email"
  type = "EMAIL"

  property {
    key   = "email"
    value = var.alerta_email
  }
}

resource "newrelic_notification_channel" "email" {
  count = local.nr_email

  name           = "oficina-api-${var.ambiente}-email"
  type           = "EMAIL"
  product        = "IINT"
  destination_id = newrelic_notification_destination.email[0].id

  property {
    key   = "subject"
    value = "{{ issueTitle }}"
  }
}

resource "newrelic_workflow" "email" {
  count = local.nr_email

  name                  = "AWS-Oficina-${local.amb}"
  muting_rules_handling = "NOTIFY_ALL_ISSUES"

  issues_filter {
    name = "politica-oficina-${var.ambiente}"
    type = "FILTER"

    predicate {
      attribute = "labels.policyIds"
      operator  = "EXACTLY_MATCHES"
      values    = [newrelic_alert_policy.oficina[0].id]
    }
  }

  destination {
    channel_id = newrelic_notification_channel.email[0].id
  }
}

resource "newrelic_nrql_alert_condition" "latencia_p95" {
  for_each = var.enable_newrelic ? local.servicos_newrelic : {}

  policy_id          = newrelic_alert_policy.oficina[0].id
  name               = "AWS-Oficina-${local.amb}-${each.value.recurso}-LatenciaP95-Warning"
  description        = "Latência p95 de ${each.value.app} acima de 1 s. Runbook: ${local.runbook_base}/api-latencia-alta.md"
  runbook_url        = "${local.runbook_base}/api-latencia-alta.md"
  type               = "static"
  aggregation_window = 60
  aggregation_method = "event_flow"
  aggregation_delay  = 120

  nrql {
    query = "SELECT percentile(duration, 95) * 1000 FROM Transaction WHERE appName = '${each.value.app}' AND transactionType = 'Web'"
  }

  warning {
    operator              = "above"
    threshold             = 1000
    threshold_duration    = 600
    threshold_occurrences = "all"
  }
}

resource "newrelic_nrql_alert_condition" "taxa_erro_5xx" {
  for_each = var.enable_newrelic ? local.servicos_newrelic : {}

  policy_id          = newrelic_alert_policy.oficina[0].id
  name               = "AWS-Oficina-${local.amb}-${each.value.recurso}-TaxaErro5xx-Critical"
  description        = "Respostas 5xx de ${each.value.app} acima de 2%. Runbook: ${local.runbook_base}/api-taxa-erro.md"
  runbook_url        = "${local.runbook_base}/api-taxa-erro.md"
  type               = "static"
  aggregation_window = 60
  aggregation_method = "event_flow"
  aggregation_delay  = 120

  nrql {
    query = "SELECT percentage(count(*), WHERE httpResponseCode LIKE '5%') FROM Transaction WHERE appName = '${each.value.app}' AND transactionType = 'Web'"
  }

  critical {
    operator              = "above"
    threshold             = 2
    threshold_duration    = 300
    threshold_occurrences = "all"
  }
}

resource "newrelic_nrql_alert_condition" "memoria_pod" {
  for_each = var.enable_newrelic ? local.servicos_newrelic : {}

  policy_id          = newrelic_alert_policy.oficina[0].id
  name               = "AWS-Oficina-${local.amb}-${each.value.recurso}-MemoriaPod-Warning"
  description        = "Memória de um pod de ${each.value.deployment} acima de 85% do limite. Runbook: ${local.runbook_base}/k8s-memoria-pod.md"
  runbook_url        = "${local.runbook_base}/k8s-memoria-pod.md"
  type               = "static"
  aggregation_window = 60
  aggregation_method = "event_flow"
  aggregation_delay  = 120

  nrql {
    query = "SELECT max(memoryWorkingSetUtilization) FROM K8sContainerSample WHERE ${local.filtro_k8s} AND deploymentName = '${each.value.deployment}'"
  }

  warning {
    operator              = "above"
    threshold             = 85
    threshold_duration    = 600
    threshold_occurrences = "all"
  }
}

resource "newrelic_nrql_alert_condition" "mensageria_dlq" {
  count = local.nr_enabled

  policy_id          = newrelic_alert_policy.oficina[0].id
  name               = "AWS-Oficina-${local.amb}-Mensageria-DLQ-Critical"
  description        = "Mensagem na DLQ após 5 tentativas de consumo. Runbook: ${local.runbook_base}/mensageria-dlq.md"
  runbook_url        = "${local.runbook_base}/mensageria-dlq.md"
  type               = "static"
  aggregation_window = 60
  aggregation_method = "event_flow"
  aggregation_delay  = 120

  nrql {
    query = "SELECT max(oficina.mensageria.dlq.mensagens) FROM Metric WHERE env = '${var.ambiente}' FACET fila"
  }

  critical {
    operator              = "above"
    threshold             = 0
    threshold_duration    = 60
    threshold_occurrences = "at_least_once"
  }
}

resource "newrelic_nrql_alert_condition" "saga_falha" {
  count = local.nr_enabled

  policy_id          = newrelic_alert_policy.oficina[0].id
  name               = "AWS-Oficina-${local.amb}-Saga-Falha-Critical"
  description        = "Saga em FALHA, aguardando intervenção manual. Runbook: ${local.runbook_base}/saga-falha.md"
  runbook_url        = "${local.runbook_base}/saga-falha.md"
  type               = "static"
  aggregation_window = 60
  aggregation_method = "event_flow"
  aggregation_delay  = 120

  nrql {
    query = "SELECT sum(oficina.saga.falhas) FROM Metric WHERE env = '${var.ambiente}'"
  }

  critical {
    operator              = "above"
    threshold             = 0
    threshold_duration    = 60
    threshold_occurrences = "at_least_once"
  }
}

resource "newrelic_nrql_alert_condition" "saga_compensacoes" {
  count = local.nr_enabled

  policy_id          = newrelic_alert_policy.oficina[0].id
  name               = "AWS-Oficina-${local.amb}-Saga-Compensacoes-Warning"
  description        = "Mais de 5 sagas compensadas em 15 minutos. Runbook: ${local.runbook_base}/saga-compensacoes.md"
  runbook_url        = "${local.runbook_base}/saga-compensacoes.md"
  type               = "static"
  aggregation_window = 900
  aggregation_method = "event_flow"
  aggregation_delay  = 120

  nrql {
    query = "SELECT sum(oficina.saga.compensadas) FROM Metric WHERE env = '${var.ambiente}'"
  }

  warning {
    operator              = "above"
    threshold             = 5
    threshold_duration    = 900
    threshold_occurrences = "at_least_once"
  }
}

resource "newrelic_nrql_alert_condition" "mercadopago_falhas" {
  count = local.nr_enabled

  policy_id          = newrelic_alert_policy.oficina[0].id
  name               = "AWS-Oficina-${local.amb}-MercadoPago-Falhas-Warning"
  description        = "Chamadas ao Mercado Pago sem sucesso. Runbook: ${local.runbook_base}/mercadopago-falhas.md"
  runbook_url        = "${local.runbook_base}/mercadopago-falhas.md"
  type               = "static"
  aggregation_window = 60
  aggregation_method = "event_flow"
  aggregation_delay  = 120

  nrql {
    query = "SELECT sum(oficina.integracao.mercadopago) FROM Metric WHERE env = '${var.ambiente}' AND resultado != 'sucesso'"
  }

  warning {
    operator              = "above"
    threshold             = 0
    threshold_duration    = 300
    threshold_occurrences = "at_least_once"
  }
}

resource "newrelic_nrql_alert_condition" "os_falha_transicao" {
  count = local.nr_enabled

  policy_id                    = newrelic_alert_policy.oficina[0].id
  name                         = "AWS-Oficina-${local.amb}-OS-FalhaTransicao-Critical"
  description                  = "Falha ao mudar status de OS. Runbook: ${local.runbook_base}/os-falha-transicao.md"
  runbook_url                  = "${local.runbook_base}/os-falha-transicao.md"
  type                         = "static"
  aggregation_window           = 60
  aggregation_method           = "event_flow"
  aggregation_delay            = 120
  violation_time_limit_seconds = 86400

  nrql {
    query = "SELECT sum(oficina.os.transicoes) FROM Metric WHERE env = '${var.ambiente}' AND resultado = 'falha'"
  }

  critical {
    operator              = "above"
    threshold             = 5
    threshold_duration    = 300
    threshold_occurrences = "all"
  }
}

resource "newrelic_synthetics_monitor" "health" {
  count = local.nr_enabled

  name             = "AWS-Oficina-${local.amb}-Health"
  type             = "SIMPLE"
  status           = "ENABLED"
  period           = "EVERY_5_MINUTES"
  uri              = "${local.api_url}/actuator/health"
  locations_public = ["AWS_US_EAST_1", "AWS_US_WEST_1", "AWS_SA_EAST_1"]

  treat_redirect_as_failure = true
  verify_ssl                = true
  validation_string         = "UP"
  bypass_head_request       = true
}

resource "newrelic_nrql_alert_condition" "uptime" {
  count = local.nr_enabled

  policy_id          = newrelic_alert_policy.oficina[0].id
  name               = "AWS-Oficina-${local.amb}-Health-Uptime-Critical"
  description        = "Healthcheck falhou. Runbook: ${local.runbook_base}/health-uptime.md"
  runbook_url        = "${local.runbook_base}/health-uptime.md"
  type               = "static"
  aggregation_window = 60
  aggregation_method = "event_flow"
  aggregation_delay  = 180

  nrql {
    query = "SELECT count(*) FROM SyntheticCheck WHERE monitorName = '${newrelic_synthetics_monitor.health[0].name}' AND result = 'FAILED'"
  }

  critical {
    operator              = "above_or_equals"
    threshold             = 2
    threshold_duration    = 600
    threshold_occurrences = "all"
  }
}

resource "newrelic_one_dashboard" "negocio" {
  count = local.nr_enabled

  name        = "Oficina — Negócio (${local.amb})"
  permissions = "public_read_only"

  page {
    name = "Ordens de serviço"

    widget_line {
      title  = "Volume diário de ordens de serviço"
      row    = 1
      column = 1
      width  = 6
      height = 3

      nrql_query {
        query = "SELECT sum(oficina.os.abertas) FROM Metric WHERE env = '${var.ambiente}' TIMESERIES 1 day SINCE 30 days ago"
      }
    }

    widget_billboard {
      title  = "OS abertas hoje"
      row    = 1
      column = 7
      width  = 6
      height = 3

      nrql_query {
        query = "SELECT sum(oficina.os.abertas) FROM Metric WHERE env = '${var.ambiente}' SINCE today"
      }
    }

    widget_line {
      title  = "Tempo médio de execução por status"
      row    = 4
      column = 1
      width  = 12
      height = 3

      nrql_query {
        query = "SELECT average(oficina.os.duracao_status) FROM Metric WHERE env = '${var.ambiente}' AND status_origem IN ('EM_DIAGNOSTICO', 'EM_EXECUCAO', 'FINALIZADA') FACET status_origem TIMESERIES AUTO"
      }
    }

    widget_bar {
      title  = "Erros e falhas nas integrações"
      row    = 7
      column = 1
      width  = 6
      height = 3

      nrql_query {
        query = "SELECT sum(oficina.integracao.falhas) FROM Metric WHERE env = '${var.ambiente}' FACET integracao, motivo SINCE 1 day ago"
      }
    }

    widget_table {
      title  = "Transições por status"
      row    = 7
      column = 7
      width  = 6
      height = 3

      nrql_query {
        query = "SELECT sum(oficina.os.transicoes) FROM Metric WHERE env = '${var.ambiente}' FACET status_destino, resultado SINCE 1 day ago LIMIT 20"
      }
    }
  }
}

resource "newrelic_one_dashboard" "tecnico" {
  count = local.nr_enabled

  name        = "Oficina — Técnico (${local.amb})"
  permissions = "public_read_only"

  page {
    name = "Aplicação e cluster"

    widget_line {
      title  = "Latência p95 e p99 por endpoint"
      row    = 1
      column = 1
      width  = 6
      height = 3

      nrql_query {
        query = "SELECT percentile(duration, 95, 99) * 1000 FROM Transaction WHERE appName = '${local.nome}' TIMESERIES AUTO"
      }
    }

    widget_line {
      title  = "Taxa de erro 4xx vs 5xx"
      row    = 1
      column = 7
      width  = 6
      height = 3

      nrql_query {
        query = "SELECT count(*) FROM Transaction WHERE appName = '${local.nome}' FACET httpResponseCode TIMESERIES AUTO"
      }
    }

    widget_line {
      title  = "CPU e memória por pod"
      row    = 4
      column = 1
      width  = 6
      height = 3

      nrql_query {
        query = "SELECT average(cpuUsedCores), average(memoryWorkingSetBytes)/1e6 FROM K8sContainerSample WHERE containerName = 'oficina-api' FACET podName TIMESERIES AUTO"
      }
    }

    widget_billboard {
      title  = "Réplicas ativas (HPA)"
      row    = 4
      column = 7
      width  = 3
      height = 3

      nrql_query {
        query = "SELECT latest(podsAvailable) FROM K8sDeploymentSample WHERE deploymentName = 'oficina-api'"
      }
    }

    widget_billboard {
      title  = "Apdex"
      row    = 4
      column = 10
      width  = 3
      height = 3

      nrql_query {
        query = "SELECT apdex(duration, t: 0.5) FROM Transaction WHERE appName = '${local.nome}'"
      }
    }
  }
}
