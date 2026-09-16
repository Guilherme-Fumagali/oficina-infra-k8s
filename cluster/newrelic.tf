locals {
  amb        = title(var.ambiente)
  nr_enabled = var.enable_newrelic ? 1 : 0

  runbook_base = "https://github.com/Guilherme-Fumagali/tech-challenge-1/blob/main/docs/runbooks"
}

resource "newrelic_alert_policy" "oficina" {
  count               = local.nr_enabled
  name                = "AWS-OficinaAPI-${local.amb}"
  incident_preference = "PER_CONDITION_AND_TARGET"
}

resource "newrelic_notification_destination" "email" {
  count = var.enable_newrelic && var.alerta_email != "" ? 1 : 0

  name = "oficina-api-${var.ambiente}-email"
  type = "EMAIL"

  property {
    key   = "email"
    value = var.alerta_email
  }
}

resource "newrelic_nrql_alert_condition" "os_falha_transicao" {
  count = local.nr_enabled

  policy_id                    = newrelic_alert_policy.oficina[0].id
  name                         = "AWS-OficinaAPI-${local.amb}-OS-FalhaTransicao-Critical"
  description                  = "Falha ao mudar status de OS. Runbook: ${local.runbook_base}/os-falha-transicao.md"
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

resource "newrelic_nrql_alert_condition" "api_latencia_p95" {
  count = local.nr_enabled

  policy_id          = newrelic_alert_policy.oficina[0].id
  name               = "AWS-OficinaAPI-${local.amb}-API-LatenciaP95-Warning"
  description        = "Latência p95 acima de 1s. Runbook: ${local.runbook_base}/api-latencia-alta.md"
  type               = "static"
  aggregation_window = 60
  aggregation_method = "event_flow"
  aggregation_delay  = 120

  nrql {
    query = "SELECT percentile(duration, 95) * 1000 FROM Transaction WHERE appName = '${local.nome}'"
  }

  warning {
    operator              = "above"
    threshold             = 1000
    threshold_duration    = 600
    threshold_occurrences = "all"
  }
}

resource "newrelic_nrql_alert_condition" "api_taxa_erro" {
  count = local.nr_enabled

  policy_id          = newrelic_alert_policy.oficina[0].id
  name               = "AWS-OficinaAPI-${local.amb}-API-TaxaErro5xx-Critical"
  description        = "Erro de servidor acima de 2%. Runbook: ${local.runbook_base}/api-taxa-erro.md"
  type               = "static"
  aggregation_window = 60
  aggregation_method = "event_flow"
  aggregation_delay  = 120

  nrql {
    query = "SELECT percentage(count(*), WHERE error IS true) FROM Transaction WHERE appName = '${local.nome}'"
  }

  critical {
    operator              = "above"
    threshold             = 2
    threshold_duration    = 300
    threshold_occurrences = "all"
  }
}

resource "newrelic_nrql_alert_condition" "k8s_memoria_pod" {
  count = local.nr_enabled

  policy_id          = newrelic_alert_policy.oficina[0].id
  name               = "AWS-OficinaAPI-${local.amb}-K8s-MemoriaPod-Warning"
  description        = "Memória de pod acima de 85%. Runbook: ${local.runbook_base}/k8s-memoria-pod.md"
  type               = "static"
  aggregation_window = 60
  aggregation_method = "event_flow"
  aggregation_delay  = 120

  nrql {
    query = "SELECT max(memoryWorkingSetUtilization) FROM K8sContainerSample WHERE containerName = 'oficina-api'"
  }

  warning {
    operator              = "above"
    threshold             = 85
    threshold_duration    = 600
    threshold_occurrences = "all"
  }
}

resource "newrelic_nrql_alert_condition" "integracao_falhas" {
  count = local.nr_enabled

  policy_id          = newrelic_alert_policy.oficina[0].id
  name               = "AWS-OficinaAPI-${local.amb}-Integracao-Falhas-Warning"
  description        = "Falhas de integração acima do normal. Runbook: ${local.runbook_base}/integracao-falhas.md"
  type               = "static"
  aggregation_window = 60
  aggregation_method = "event_flow"
  aggregation_delay  = 120

  nrql {
    query = "SELECT sum(oficina.integracao.falhas) FROM Metric WHERE env = '${var.ambiente}'"
  }

  warning {
    operator              = "above"
    threshold             = 10
    threshold_duration    = 900
    threshold_occurrences = "all"
  }
}

resource "newrelic_synthetics_monitor" "health" {
  count = local.nr_enabled

  name             = "AWS-OficinaAPI-${local.amb}-Health"
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
  name               = "AWS-OficinaAPI-${local.amb}-Health-Uptime-Critical"
  description        = "Healthcheck falhou. Runbook: ${local.runbook_base}/health-uptime.md"
  type               = "static"
  aggregation_window = 60
  aggregation_method = "event_flow"
  aggregation_delay  = 180

  nrql {
    query = "SELECT count(*) FROM SyntheticCheck WHERE monitorName = 'AWS-OficinaAPI-${local.amb}-Health' AND result = 'FAILED'"
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
