#!/usr/bin/env bash
# =========================================================================================
# Instalação Automatizada do AdGuard Home (LXC) para Proxmox VE 9+ (Otimizado)
# =========================================================================================

set -e # Interrompe o script se houver qualquer erro

echo -e "\n🟢 Iniciando o Proxmox 9 AdGuard Home LXC Builder..."

# 1. Coleta Automática de ID e Variáveis do Usuário
CT_ID=$(pvesh get /cluster/nextid)
echo "👉 Próximo ID livre encontrado: $CT_ID"

read -p "Interface de ponte (ex: vmbr0, vmbr1) [Padrão: vmbr1]: " INPUT_BRIDGE < /dev/tty
CT_BRIDGE=${INPUT_BRIDGE:-vmbr1}

read -p "IP com máscara (ex: 10.0.0.53/24) ou dhcp [Padrão: dhcp]: " INPUT_IP < /dev/tty
CT_IP=${INPUT_IP:-dhcp}

if [ "$CT_IP" != "dhcp" ]; then
    read -p "Gateway (ex: 10.0.0.1): " CT_GW < /dev/tty
fi

CT_NAME="AdGuard-Home"
CT_RAM=512
CT_CORES=1
CT_DISK=4

# 2. Gerenciamento Inteligente de Templates (Evita downloads repetidos)
echo -e "\n⏳ Verificando os templates do Debian existentes no Proxmox..."

# Varre os storages locais em busca de um template Debian pré-existente (.tar.zst ou .tar.gz)
LOCAL_TEMPLATE=$(pveam list local 2>/dev/null | grep -E 'debian-12|debian-13' | awk '{print $1}' | tail -n 1) || true

if [ -n "$LOCAL_TEMPLATE" ]; then
    echo "✅ Template local encontrado: $LOCAL_TEMPLATE (Ignorando download)"
    TEMPLATE_PATH="$LOCAL_TEMPLATE"
else
    echo "🔍 Nenhum template local do Debian 12/13 encontrado. Buscando nos repositórios oficiais..."
    pveam update >/dev/null
    ONLINE_TEMPLATE=$(pveam available -section system | grep -E 'debian-12-standard|debian-13-standard' | awk '{print $2}' | tail -n 1)
    
    if [ -z "$ONLINE_TEMPLATE" ]; then
        echo "❌ Erro: Nenhum template do Debian encontrado online ou localmente."
        exit 1
    fi
    
    echo "📥 Baixando $ONLINE_TEMPLATE para o storage local..."
    pveam download local "$ONLINE_TEMPLATE" >/dev/null
    TEMPLATE_PATH="local:vztmpl/$(basename $ONLINE_TEMPLATE)"
fi

# 3. Construção do Container LXC
echo -e "\n🛠️ Construindo o Container LXC $CT_ID..."
if [ "$CT_IP" == "dhcp" ]; then
    pct create $CT_ID "$TEMPLATE_PATH" \
        --ostype debian --arch amd64 \
        --hostname $CT_NAME \
        --cores $CT_CORES --memory $CT_RAM --swap 0 \
        --rootfs local-lvm:${CT_DISK} \
        --net0 name=eth0,bridge=${CT_BRIDGE},ip=dhcp \
        --unprivileged 1 \
        --features nesting=1
else
    pct create $CT_ID "$TEMPLATE_PATH" \
        --ostype debian --arch amd64 \
        --hostname $CT_NAME \
        --cores $CT_CORES --memory $CT_RAM --swap 0 \
        --rootfs local-lvm:${CT_DISK} \
        --net0 name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GW} \
        --unprivileged 1 \
        --features nesting=1
fi

# 4. Inicialização e Configuração do Sistema Operacional
echo "🚀 Iniciando o LXC..."
pct start $CT_ID
echo "⏳ Aguardando a rede subir dentro do container (10 segundos)..."
sleep 10

echo "📦 Atualizando pacotes no container e instalando curl/sudo..."
pct exec $CT_ID -- apt-get update -y >/dev/null
pct exec $CT_ID -- apt-get install -y curl sudo >/dev/null

# 5. Instalação Oficial do AdGuard Home via Binário
echo "🛡️ Instalando o AdGuard Home..."
pct exec $CT_ID -- bash -c "curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v"

# 6. Conclusão e Exibição de Credenciais
echo -e "\n======================================================================"
echo "✅ Instalação Concluída com Sucesso no Proxmox 9!"
echo "======================================================================"
if [ "$CT_IP" == "dhcp" ]; then
    echo "Como você escolheu DHCP, verifique o IP que o roteador atribuiu."
    echo "Acesse no navegador: http://<IP_DO_LXC>:3000"
else
    CLEAN_IP=$(echo $CT_IP | cut -d'/' -f1)
    echo "Acesse o painel de configuração inicial em:"
    echo "👉 http://${CLEAN_IP}:3000"
fi
echo "======================================================================"
