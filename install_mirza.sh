#!/usr/bin/env bash

set -e

echo "==== Mirza Pro Auto Installer ===="

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run the script as root (sudo su or sudo bash install_mirza.sh)."
  exit 1
fi

### 1. Collect information from user
read -p "Enter your domain (example: bot.example.com): " DOMAIN
read -p "Enter your email for SSL (Let's Encrypt): " EMAIL

read -p "Database name (default: mirza_pro): " DB_NAME
DB_NAME=${DB_NAME:-mirza_pro}

read -p "Database username (default: mirza_user): " DB_USER
DB_USER=${DB_USER:-mirza_user}

read -sp "Database password: " DB_PASS
echo ""

read -p "Telegram bot token (from BotFather): " BOT_TOKEN
read -p "Admin Telegram ID (numeric): " ADMIN_ID
read -p "Bot username without @ (example: my_mirza_bot): " BOT_USERNAME

read -p "Are you using NEW Marzban panel? (y/n): " USE_MARZBAN
USE_MARZBAN=${USE_MARZBAN,,}

echo ""
echo "Domain: $DOMAIN"
echo "Email: $EMAIL"
echo "Database: $DB_NAME / $DB_USER"
echo "Bot username: @$BOT_USERNAME"
echo "Admin ID: $ADMIN_ID"
echo ""
read -p "Is the above information correct? (y/n): " CONFIRM
CONFIRM=${CONFIRM,,}
if [ "$CONFIRM" != "y" ]; then
  echo "Installation cancelled."
  exit 1
fi

### 2. Update system & install Apache, PHP, MySQL, etc.
echo "==> Updating system & installing Apache, PHP 8.2, MySQL, git, certbot ..."
apt update && apt upgrade -y

apt install -y apache2 mysql-server git software-properties-common

add-apt-repository ppa:ondrej/php -y
apt update

apt install -y \
  php8.2 libapache2-mod-php8.2 \
  php8.2-cli php8.2-common php8.2-mbstring php8.2-curl \
  php8.2-xml php8.2-zip php8.2-mysql php8.2-gd php8.2-bcmath

apt install -y certbot python3-certbot-apache

a2dismod php7.4 php8.0 php8.1 2>/dev/null || true
a2enmod php8.2 rewrite
systemctl restart apache2

echo "==> Current PHP version:"
php -v || true

### 3. Create database and user
echo "==> Creating MySQL database and user ..."
mysql -u root <<MYSQL_EOF
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
MYSQL_EOF

### 4. Clone Mirza Pro source
echo "==> Cloning Mirza Pro ..."
cd /var/www
if [ -d "mirza_pro" ]; then
  echo "/var/www/mirza_pro already exists. Skipping clone."
else
  git clone https://github.com/mahdiMGF2/mirza_pro.git
fi

cd /var/www/mirza_pro
chown -R www-data:www-data /var/www/mirza_pro

### 5. Create Apache VirtualHost
echo "==> Creating Apache VirtualHost ..."
cat >/etc/apache2/sites-available/mirza-pro.conf <<EOF
<VirtualHost *:80>
    ServerName $DOMAIN
    DocumentRoot /var/www/mirza_pro

    <Directory /var/www/mirza_pro>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/mirza_error.log
    CustomLog \${APACHE_LOG_DIR}/mirza_access.log combined
</VirtualHost>
EOF

a2ensite mirza-pro.conf
a2dissite 000-default.conf || true
systemctl reload apache2

### 6. Write config.php
echo "==> Writing config.php ..."
CONFIG_PATH="/var/www/mirza_pro/config.php"

if [ -f "$CONFIG_PATH" ] && [ ! -f "${CONFIG_PATH}.bak" ]; then
  cp "$CONFIG_PATH" "${CONFIG_PATH}.bak" || true
fi

cat >"$CONFIG_PATH" <<PHP
<?php
// ================= DATABASE =================
\$dbname     = '$DB_NAME';
\$usernamedb = '$DB_USER';
\$passworddb = '$DB_PASS';

\$connect = mysqli_connect("localhost", \$usernamedb, \$passworddb, \$dbname);
if (\$connect->connect_error) { die("error" . \$connect->connect_error); }
mysqli_set_charset(\$connect, "utf8mb4");

\$options = [
    PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
    PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    PDO::ATTR_EMULATE_PREPARES   => false,
];
\$dsn = "mysql:host=localhost;dbname=\$dbname;charset=utf8mb4";
\$pdo = new PDO(\$dsn, \$usernamedb, \$passworddb, \$options);

// ================= TELEGRAM BOT =================
\$APIKEY      = '$BOT_TOKEN';
\$adminnumber = '$ADMIN_ID';
\$domainhosts = 'https://$DOMAIN';
\$usernamebot = '$BOT_USERNAME';

PHP

if [ "$USE_MARZBAN" == "y" ]; then
  cat >>"$CONFIG_PATH" <<'PHP'
$new_marzban = true;
PHP
else
  cat >>"$CONFIG_PATH" <<'PHP'
// $new_marzban = true;
PHP
fi

cat >>"$CONFIG_PATH" <<'PHP'
?>
PHP

chown www-data:www-data "$CONFIG_PATH"

### 7. Run table.php
echo "==> Running table.php ..."
cd /var/www/mirza_pro
php table.php || true

### 8. SSL via Certbot
echo "==> Obtaining SSL certificate ..."
certbot --apache -d "$DOMAIN" -m "$EMAIL" --agree-tos --redirect --non-interactive || true

### 9. Telegram Webhook
echo "==> Setting Telegram webhook ..."
WEBHOOK_URL="https://$DOMAIN/index.php"
curl -s "https://api.telegram.org/bot$BOT_TOKEN/deleteWebhook" >/dev/null 2>&1 || true

WEBHOOK_RESULT=$(curl -s "https://api.telegram.org/bot$BOT_TOKEN/setWebhook?url=$WEBHOOK_URL")
echo "Webhook response: $WEBHOOK_RESULT"

### 10. Cron jobs
echo "==> Installing cron jobs (WARNING: This will overwrite existing crontab!) ..."
crontab - <<EOF
* * * * * php /var/www/mirza_pro/cronbot/NoticationsService.php >/dev/null 2>&1
*/5 * * * * php /var/www/mirza_pro/cronbot/uptime_panel.php >/dev/null 2>&1
*/5 * * * * php /var/www/mirza_pro/cronbot/uptime_node.php >/dev/null 2>&1
*/10 * * * * php /var/www/mirza_pro/cronbot/expireagent.php >/dev/null 2>&1
*/10 * * * * php /var/www/mirza_pro/cronbot/payment_expire.php >/dev/null 2>&1
0 * * * * php /var/www/mirza_pro/cronbot/statusday.php >/dev/null 2>&1
0 3 * * * php /var/www/mirza_pro/cronbot/backupbot.php >/dev/null 2>&1
*/15 * * * * php /var/www/mirza_pro/cronbot/iranpay1.php >/dev/null 2>&1
*/15 * * * * php /var/www/mirza_pro/cronbot/plisio.php >/dev/null 2>&1
EOF

echo "===== Installation FINISHED Successfully 🎉 ====="
echo "Now go to Telegram and send /start to @$BOT_USERNAME"
echo "If admin panel didn't show up, check the 'admin' table in database."
echo ""
echo "Mirza Pro 2 GitHub repository:       https://github.com/mahdiMGF2/mirza_pro"
echo "YouTube channel (tutorials & guides): https://www.youtube.com/@iAghapour"
