#!/bin/bash
# ==============================================================================
# Blue Team Automation: Triagem de Alertas Suricata + Correlação Splunk (SPL)
# Engenharia: Bash Puro (Preservação de Escopo / Zero Pipes Desnecessários)
# ==============================================================================

SPLUNK_URI="https://localhost:8089/services/search/jobs/export"
SPLUNK_TOKEN="SEU_TOKEN_SPLUNK_AQUI"
SURICATA_LOG="${1:-/var/log/suricata/fast.log}"
MODO_SIMULACAO=true  # Altere para 'false' para aplicar bloqueio real no firewall

# Array associativo e contador vivos na memória do Processo Pai
declare -A IPS_CONTIDOS
TOTAL_INCIDENTES=0

# Função silenciosa para consultar histórico do IP no Splunk via SPL
consultar_splunk() {
    local ip_suspeito="$1"
    local query_spl="search index=network_sec src_ip=\"${ip_suspeito}\" | stats count"
    local resposta_raw

    resposta_raw=$(curl -sk --connect-timeout 2 \
        -H "Authorization: Bearer ${SPLUNK_TOKEN}" \
        -d "search=${query_spl}" \
        -d "output_mode=csv" \
        "${SPLUNK_URI}")

    # Expansão de parâmetro nativa: descarta o cabeçalho CSV sem usar 'tail'
    SPLUNK_HITS="${resposta_raw#*$'\n'}"
    [[ -z "$SPLUNK_HITS" || "$SPLUNK_HITS" == "count" ]] && SPLUNK_HITS="0 (SIEM Offline/Simulação)"
}

# Validação prévia do ficheiro de log
if [[ ! -r "$SURICATA_LOG" ]]; then
    printf "[ERRO] Ficheiro de log inacessível: %s\n" "$SURICATA_LOG" >&2
    exit 1
fi

# Bloco principal alimentado por redirecionamento direto (<) no final do 'done'.
# Evita o 'cat ficheiro | while', garantindo que TOTAL_INCIDENTES e IPS_CONTIDOS
# sobrevivam na RAM após o término do loop.
while IFS= read -r linha; do

    # Regex nativa do Bash: filtra apenas Prioridade 1 ou 2 e extrai o IP de origem
    if [[ "$linha" =~ \[Priority:\ ([12])\].*\{[A-Z]+\}\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):[0-9]+\ -\> ]]; then
        prioridade="${BASH_REMATCH[1]}"
        ip_origem="${BASH_REMATCH[2]}"

        # Ignora se o IP já foi tratado nesta execução (deduplicação em memória)
        [[ -n "${IPS_CONTIDOS[$ip_origem]}" ]] && continue

        # Agrupamento anónimo no processo pai para enriquecimento e ação
        {
            consultar_splunk "$ip_origem"
            IPS_CONTIDOS["$ip_origem"]="Prioridade:$prioridade"
            ((TOTAL_INCIDENTES++))

            if [[ "$MODO_SIMULACAO" == true ]]; then
                printf "[SIMULAÇÃO] IP %-15s | Prio: %s | Eventos Splunk: %s -> Bloqueio preparado.\n" \
                    "$ip_origem" "$prioridade" "$SPLUNK_HITS"
            else
                iptables -I INPUT -s "$ip_origem" -j DROP
                printf "[CONTIDO]   IP %-15s | Prio: %s | Eventos Splunk: %s -> Bloqueado no firewall.\n" \
                    "$ip_origem" "$prioridade" "$SPLUNK_HITS"
            fi
        }
    fi

done < "$SURICATA_LOG"

# Pronunciamento final lendo diretamente da RAM do Processo Pai
printf "\n=== Resumo da Operação ===\n"
printf "Total de ameaças únicas contidas: %d\n" "$TOTAL_INCIDENTES"
