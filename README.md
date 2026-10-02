# CheckUser Dual — DTunnel + Void Pro+

Instalador autocontido para publicar **um único CheckUser na porta 2052**, atendendo o DTunnel e o Void Pro+.

A versão dual consulta primeiro o contador interno do DragonCore. Assim, o campo `count_connections` representa o usuário consultado, e não um valor fixo global.

## Como funciona

```text
DTunnel ───────┐
               ├── /check?user=...&uuid=...&hwid=... ──> CheckUser :2052
Void Pro+ ─────┘                                      │
                                                      ├── DragonCore /check
                                                      └── fallback local
```

Quando o usuário está conectado:

```json
{
  "username": "ldk22",
  "count_connections": 1,
  "limit_connections": 1
}
```

Quando está desconectado, o contador volta para `0`. O resultado é individual por usuário.

## Instalação

O arquivo `install-checkuser.sh` é autocontido: o binário dual já está embutido. Não é necessário instalar Go, baixar outro binário ou criar Release.

Na VPS, como `root`:

```bash
wget -qO /tmp/i https://raw.githubusercontent.com/Willapela/check-final/main/install-checkuser.sh && sed -i 's/\r$//' /tmp/i && chmod +x /tmp/i && bash /tmp/i
```

A linha `sed` corrige arquivos enviados pelo GitHub pelo celular que estejam com quebra de linha Windows.

## Configuração do DragonCore

Por padrão, o instalador usa:

```text
http://vp.dspeed.shop:9090
```

Para conferir:

```bash
systemctl cat check-dt-voidpro.service | grep dragoncore-url
```

Também é possível alterar a URL antes da instalação:

```bash
DRAGONCORE_URL='http://IP_DO_PAINEL:PORTA' bash ./install-checkuser.sh
```

A URL deve ser a base, sem `/check` no final. O programa adiciona `/check` automaticamente.

## URLs para os aplicativos

Use o endereço do Cloudflare exibido pelo comando `check`.

### Void Pro+

```text
https://SEU-LINK.trycloudflare.com/check?user={username}&uuid={uuid}&hwid={hwid}
```

### DTunnel

Use a mesma rota `/check` com os placeholders aceitos pelo seu aplicativo:

```text
https://SEU-LINK.trycloudflare.com/check?user={username}&uuid={uuid}&hwid={hwid}
```

Não use somente o domínio sem `/check`; o endereço base serve apenas para verificar se o serviço está online.

## Menu de controle

```bash
check
```

O painel mostra:

- estado do CheckUser;
- estado do Cloudflare;
- porta ativa;
- fonte da contagem;
- link público do DTunnel;
- URL completa do Void Pro+;
- logs do Cloudflare;
- opção para reiniciar e gerar outro link;
- opção segura para remover somente o CheckUser e o Tunnel.

A opção de remoção preserva:

```text
/root/usuarios.db
/etc/SSHPlus
usuários do SSHPlus
```

## Diagnóstico

```bash
systemctl status check-dt-voidpro.service --no-pager -l
systemctl status check-dt-voidpro-tunnel.service --no-pager -l
journalctl -u check-dt-voidpro-tunnel.service --no-pager -n 100 -o cat
```

Teste local com um usuário conectado:

```bash
curl -sS \
  'http://127.0.0.1:2052/check?user=ldk22&uuid=teste&hwid=teste'
```

O serviço dual deve apresentar:

```bash
/usr/local/lib/check-dt-voidpro/checkuser -version
```

Resultado esperado:

```text
checkuser dual-dragoncore-1.0.0
```

Se o DragonCore estiver indisponível, a ponte usa o fallback local. Nesse modo, a contagem pode retornar `0` para conexões que não aparecem como processos `sshd` ou `dropbear`.

## Arquivos e serviços

| Item | Caminho |
|---|---|
| Binário dual | `/usr/local/lib/check-dt-voidpro/checkuser` |
| Serviço CheckUser | `/etc/systemd/system/check-dt-voidpro.service` |
| Serviço Tunnel | `/etc/systemd/system/check-dt-voidpro-tunnel.service` |
| Menu | `/usr/local/bin/check` |
| Log do Tunnel | `/var/log/check-dt-voidpro-tunnel.log` |
| Fallback de limites | `/root/usuarios.db` |
