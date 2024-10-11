provider "kubernetes" {
  config_path = "~/.kube/config"
}

resource "kubernetes_namespace" "grafana_ha" {
  metadata {
    name = "grafana-ha"
  }
}

resource "kubernetes_persistent_volume_claim" "postgres_pvc" {
  metadata {
    name      = "postgres-pvc"
    namespace = kubernetes_namespace.grafana_ha.metadata[0].name
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "5Gi"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "grafana_pvc" {
  metadata {
    name      = "grafana-pvc"
    namespace = kubernetes_namespace.grafana_ha.metadata[0].name
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "5Gi"
      }
    }
  }
}

resource "kubernetes_config_map" "grafana_config" {
  metadata {
    name      = "grafana-config"
    namespace = kubernetes_namespace.grafana_ha.metadata[0].name
  }

  data = {
    "grafana.ini" = <<-EOT
      [database]
      type = postgres
      host = postgres:5432
      name = grafana
      user = grafana
      password = grafanapassword

      [server]
      http_port = 3001
    EOT

    "datasources.yaml" = <<-EOT
      apiVersion: 1
      datasources:
      - name: PostgreSQL
        type: postgres
        url: postgres:5432
        database: grafana
        user: grafana
        secureJsonData:
          password: grafanapassword
        jsonData:
          sslmode: "disable"
      - name: Prometheus
        type: prometheus
        url: http://prometheus:9090
        access: proxy
      - name: Loki
        type: loki
        url: http://loki:3100
        access: proxy
    EOT
  }
}

resource "kubernetes_secret" "grafana_secret" {
  metadata {
    name      = "grafana-secret"
    namespace = kubernetes_namespace.grafana_ha.metadata[0].name
  }

  data = {
    "admin-password" = "adminpassword"
  }

  type = "Opaque"
}

resource "kubernetes_deployment" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace.grafana_ha.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "postgres"
      }
    }

    template {
      metadata {
        labels = {
          app = "postgres"
        }
      }

      spec {
        container {
          name  = "postgres"
          image = "postgres:13"

          env {
            name  = "POSTGRES_DB"
            value = "grafana"
          }
          env {
            name  = "POSTGRES_USER"
            value = "grafana"
          }
          env {
            name  = "POSTGRES_PASSWORD"
            value = "grafanapassword"
          }

          port {
            container_port = 5432
          }

          volume_mount {
            name       = "postgres-storage"
            mount_path = "/var/lib/postgresql/data"
            sub_path   = "postgres"
          }
        }

        volume {
          name = "postgres-storage"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.postgres_pvc.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace.grafana_ha.metadata[0].name
  }
  spec {
    selector = {
      app = "postgres"
    }
    port {
      port = 5432
    }
  }
}

resource "kubernetes_deployment" "grafana" {
  metadata {
    name      = "grafana"
    namespace = kubernetes_namespace.grafana_ha.metadata[0].name
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = "grafana"
      }
    }

    template {
      metadata {
        labels = {
          app = "grafana"
        }
      }

      spec {
        container {
          name  = "grafana"
          image = "grafana/grafana:latest"

          port {
            container_port = 3001
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/grafana/grafana.ini"
            sub_path   = "grafana.ini"
          }

          volume_mount {
            name       = "datasources"
            mount_path = "/etc/grafana/provisioning/datasources/datasources.yaml"
            sub_path   = "datasources.yaml"
          }

          volume_mount {
            name       = "grafana-storage"
            mount_path = "/var/lib/grafana"
          }

          env {
            name = "GF_SECURITY_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.grafana_secret.metadata[0].name
                key  = "admin-password"
              }
            }
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.grafana_config.metadata[0].name
            items {
              key  = "grafana.ini"
              path = "grafana.ini"
            }
          }
        }

        volume {
          name = "datasources"
          config_map {
            name = kubernetes_config_map.grafana_config.metadata[0].name
            items {
              key  = "datasources.yaml"
              path = "datasources.yaml"
            }
          }
        }

        volume {
          name = "grafana-storage"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.grafana_pvc.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "grafana" {
  metadata {
    name      = "grafana"
    namespace = kubernetes_namespace.grafana_ha.metadata[0].name
  }
  spec {
    selector = {
      app = "grafana"
    }
    port {
      port        = 3001
      target_port = 3001
    }
    type = "LoadBalancer"
  }
}

# Prometheus resources
resource "kubernetes_config_map" "prometheus_config" {
  metadata {
    name      = "prometheus-config"
    namespace = kubernetes_namespace.grafana_ha.metadata[0].name
  }

  data = {
    "prometheus.yml" = <<-EOT
      global:
        scrape_interval: 15s
      scrape_configs:
        - job_name: 'prometheus'
          static_configs:
            - targets: ['localhost:9090']
        - job_name: 'kubernetes-pods'
          kubernetes_sd_configs:
            - role: pod
    EOT
  }
}

resource "kubernetes_deployment" "prometheus" {
  metadata {
    name      = "prometheus"
    namespace = kubernetes_namespace.grafana_ha.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "prometheus"
      }
    }

    template {
      metadata {
        labels = {
          app = "prometheus"
        }
      }

      spec {
        container {
          name  = "prometheus"
          image = "prom/prometheus"

          port {
            container_port = 9090
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/prometheus/prometheus.yml"
            sub_path   = "prometheus.yml"
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.prometheus_config.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "prometheus" {
  metadata {
    name      = "prometheus"
    namespace = kubernetes_namespace.grafana_ha.metadata[0].name
  }
  spec {
    selector = {
      app = "prometheus"
    }
    port {
      port = 9090
    }
  }
}

# Loki resources
resource "kubernetes_config_map" "loki_config" {
  metadata {
    name      = "loki-config"
    namespace = kubernetes_namespace.grafana_ha.metadata[0].name
  }

  data = {
    "loki.yaml" = <<-EOT
      auth_enabled: false
      server:
        http_listen_port: 3100
      ingester:
        lifecycler:
          address: 127.0.0.1
          ring:
            kvstore:
              store: inmemory
            replication_factor: 1
        chunk_idle_period: 5m
        chunk_retain_period: 30s
      schema_config:
        configs:
        - from: 2020-05-15
          store: boltdb
          object_store: filesystem
          schema: v11
          index:
            prefix: index_
            period: 168h
      storage_config:
        boltdb:
          directory: /tmp/loki/index
        filesystem:
          directory: /tmp/loki/chunks
      limits_config:
        enforce_metric_name: false
        reject_old_samples: true
        reject_old_samples_max_age: 168h
    EOT
  }
}

resource "kubernetes_deployment" "loki" {
  metadata {
    name      = "loki"
    namespace = kubernetes_namespace.grafana_ha.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "loki"
      }
    }

    template {
      metadata {
        labels = {
          app = "loki"
        }
      }

      spec {
        container {
          name  = "loki"
          image = "grafana/loki:2.4.0"

          port {
            container_port = 3100
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/loki/local-config.yaml"
            sub_path   = "loki.yaml"
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.loki_config.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "loki" {
  metadata {
    name      = "loki"
    namespace = kubernetes_namespace.grafana_ha.metadata[0].name
  }
  spec {
    selector = {
      app = "loki"
    }
    port {
      port = 3100
    }
  }
}