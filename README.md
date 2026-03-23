# Canary vs. Blue-Green: Estudo Comparativo de Robustez e Disponibilidade em Ambientes de Nuvem sob Condições de Instabilidade

Este repositório contém os artefatos, scripts e configurações utilizados no TCC
do curso de Ciência da Computação, cujo objetivo é comparar as estratégias de
deployment Canary e Blue-Green em ambientes Kubernetes sob condições de
instabilidade induzida via engenharia do caos.

## Sobre o projeto

O trabalho avalia o comportamento de cada estratégia de deployment em cenários
de falha controlada, medindo disponibilidade, robustez e tempo de recuperação
por meio de métricas objetivas coletadas com Prometheus e Grafana.

## Stack utilizada

- **Kubernetes (K8s)** — orquestração dos contêineres
- **ArgoCD + Argo Rollouts** — pipeline GitOps e controle de rollout
- **Chaos Mesh** — injeção de falhas (PodChaos, NetworkChaos, HTTPChaos, StressChaos)
- **k6** — geração de carga e tráfego sintético
- **Prometheus + Grafana** — coleta e visualização de métricas
- **Amazon ECR + S3** — armazenamento de imagens e logs
- **Contabo VPS** — infraestrutura de hospedagem do cluster

## Estrutura do repositório

├── k8s/               # Manifests YAML do cluster
├── argo/              # Configurações ArgoCD e Argo Rollouts
├── chaos/             # Experimentos do Chaos Mesh
├── k6/                # Scripts de geração de carga
├── grafana/           # Dashboards exportados
└── docs/              # Artigo e documentação

## Como executar

1. Provisione um cluster Kubernetes
2. Instale ArgoCD e Argo Rollouts
3. Aplique os manifests em `k8s/`
4. Configure o Chaos Mesh com os arquivos em `chaos/`
5. Execute os testes de carga com `k6 run k6/load-test.js`

## Autor

Desenvolvido como Trabalho de Conclusão de Curso — Ciência da Computação.
