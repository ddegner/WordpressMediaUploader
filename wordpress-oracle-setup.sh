#!/bin/bash
# =============================================================================
# WordPress + WP-CLI Setup Script for Oracle Cloud (Ubuntu 22.04)
# For Apple App Store Review Testing
# =============================================================================
# Run as root or with sudo: sudo bash wordpress-oracle-setup.sh
# =============================================================================

set -e  # Exit on any error

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
echo_success() { echo -e "${GREEN}[OK]${NC}   $1"; }
echo_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error()   { echo -e "${RED}[ERR]${NC}  $1"; }

# =============================================================================
# CONFIGURATION — Edit these before running
# =============================================================================

# Your server's public IP address (find in Oracle Cloud Console)
SERVER_IP="129.80.186.4"

# WordPress database settings
WP_DB_NAME="wordpress"
WP_DB_USER="wpuser"
WP_DB_PASS="$(openssl rand -base64 20 | tr -dc 'a-zA-Z0-9' | head -c 20)"

# WordPress admin account (for the reviewer to log into WP dashboard)
WP_ADMIN_USER="admin"
WP_ADMIN_PASS="$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)"
WP_ADMIN_EMAIL="admin@example.com"   # Change to your email
WP_SITE_TITLE="Test Site"

# SSH tester account (for rsync/SSH uploads — this is what your app connects to)
TESTER_USER="tester"
TESTER_PASS="$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)"

# WordPress upload path (where your app will rsync photos to)
WP_UPLOADS_PATH="/var/www/html/wp-content/uploads"

# =============================================================================
# CHECKS
# =============================================================================

echo ""
echo "=============================================="
echo " WordPress Oracle Cloud Setup Script"
echo "=============================================="
echo ""

# Must be run as root
if [ "$EUID" -ne 0 ]; then
    echo_error "Please run as root: sudo bash wordpress-oracle-setup.sh"
    exit 1
fi

if [ "$SERVER_IP" = "YOUR_SERVER_IP_HERE" ]; then
    echo_error "Please edit the script and set SERVER_IP to your Oracle Cloud server's public IP."
    exit 1
fi

echo_info "Starting setup for server: $SERVER_IP"
echo_info "This will take about 5-10 minutes..."
echo ""

# =============================================================================
# STEP 1: System Update
# =============================================================================
echo_info "Step 1/9: Updating system packages..."
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q
echo_success "System updated."

# =============================================================================
# STEP 2: Install Apache, PHP, and required extensions
# =============================================================================
echo_info "Step 2/9: Installing Apache + PHP..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
    apache2 \
    php \
    php-mysql \
    php-curl \
    php-gd \
    php-mbstring \
    php-xml \
    php-xmlrpc \
    php-soap \
    php-intl \
    php-zip \
    php-bcmath \
    php-imagick \
    unzip \
    wget \
    curl \
    rsync \
    fail2ban

echo_success "Apache and PHP installed."

# Enable Apache modules needed for WordPress
a2enmod rewrite headers expires deflate
systemctl restart apache2
echo_success "Apache modules enabled."

# =============================================================================
# STEP 3: Install and configure MySQL
# =============================================================================
echo_info "Step 3/9: Installing MySQL..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -q mysql-server
systemctl start mysql
systemctl enable mysql

# Secure MySQL and create WordPress database
mysql -e "CREATE DATABASE IF NOT EXISTS \`${WP_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "CREATE USER IF NOT EXISTS '${WP_DB_USER}'@'localhost' IDENTIFIED BY '${WP_DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON \`${WP_DB_NAME}\`.* TO '${WP_DB_USER}'@'localhost';"
mysql -e "DELETE FROM mysql.user WHERE User='';"
mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
mysql -e "DROP DATABASE IF EXISTS test;"
mysql -e "FLUSH PRIVILEGES;"

echo_success "MySQL installed and WordPress database created."

# =============================================================================
# STEP 4: Download and install WordPress
# =============================================================================
echo_info "Step 4/9: Downloading and installing WordPress..."
cd /tmp
wget -q https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz

# Copy WordPress files
cp -r wordpress/* /var/www/html/
rm -f /var/www/html/index.html  # Remove default Apache page

# Create wp-config.php
cp /var/www/html/wp-config-sample.php /var/www/html/wp-config.php
sed -i "s/database_name_here/${WP_DB_NAME}/" /var/www/html/wp-config.php
sed -i "s/username_here/${WP_DB_USER}/" /var/www/html/wp-config.php
sed -i "s/password_here/${WP_DB_PASS}/" /var/www/html/wp-config.php

# Generate unique security keys via WordPress API
curl -s https://api.wordpress.org/secret-key/1.1/salt/ > /tmp/wp-keys.php
# Replace the placeholder keys block using temp file (avoids shell quoting issues)
php -r "
\$config = file_get_contents('/var/www/html/wp-config.php');
\$keys   = file_get_contents('/tmp/wp-keys.php');
\$start  = strpos(\$config, '/**#@+');
\$end    = strpos(\$config, '/**#@-*/') + strlen('/**#@-*/');
if (\$start !== false && \$end !== false) {
    \$config = substr(\$config, 0, \$start) . \$keys . substr(\$config, \$end);
    file_put_contents('/var/www/html/wp-config.php', \$config);
}
"
rm -f /tmp/wp-keys.php

echo_success "WordPress files installed."

# =============================================================================
# STEP 5: Configure Apache for WordPress
# =============================================================================
echo_info "Step 5/9: Configuring Apache..."

cat > /etc/apache2/sites-available/wordpress.conf << EOF
<VirtualHost *:80>
    ServerName ${SERVER_IP}
    DocumentRoot /var/www/html

    <Directory /var/www/html>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/wordpress_error.log
    CustomLog \${APACHE_LOG_DIR}/wordpress_access.log combined
</VirtualHost>
EOF

a2ensite wordpress.conf
a2dissite 000-default.conf
systemctl reload apache2
echo_success "Apache configured for WordPress."

# =============================================================================
# STEP 6: Create .htaccess for WordPress permalinks
# =============================================================================
cat > /var/www/html/.htaccess << 'EOF'
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END WordPress
EOF

# =============================================================================
# STEP 7: Set correct file permissions
# =============================================================================
echo_info "Step 6/9: Setting file permissions..."

chown -R www-data:www-data /var/www/html
find /var/www/html -type d -exec chmod 755 {} \;
find /var/www/html -type f -exec chmod 644 {} \;
chmod 640 /var/www/html/wp-config.php

# Create the uploads directory and make it writable
mkdir -p "${WP_UPLOADS_PATH}"
chown -R www-data:www-data "${WP_UPLOADS_PATH}"
chmod -R 775 "${WP_UPLOADS_PATH}"

echo_success "Permissions set."

# =============================================================================
# STEP 8: Install WP-CLI and run WordPress installation
# =============================================================================
echo_info "Step 7/9: Installing WP-CLI..."
curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
mv wp-cli.phar /usr/local/bin/wp
echo_success "WP-CLI installed."

echo_info "Running WordPress installation via WP-CLI..."
sudo -u www-data wp core install \
    --path=/var/www/html \
    --url="http://${SERVER_IP}" \
    --title="${WP_SITE_TITLE}" \
    --admin_user="${WP_ADMIN_USER}" \
    --admin_password="${WP_ADMIN_PASS}" \
    --admin_email="${WP_ADMIN_EMAIL}" \
    --skip-email

# Configure WordPress to allow uploads and set permalink structure
sudo -u www-data wp rewrite structure '/%postname%/' --path=/var/www/html
sudo -u www-data wp option update uploads_use_yearmonth_folders 0 --path=/var/www/html
sudo -u www-data wp option update upload_path "${WP_UPLOADS_PATH}" --path=/var/www/html

echo_success "WordPress installed and configured."

# =============================================================================
# STEP 9: Create SSH tester user for rsync uploads
# =============================================================================
echo_info "Step 8/9: Creating SSH tester user..."

# Create the tester user
if id "$TESTER_USER" &>/dev/null; then
    echo_warn "User '$TESTER_USER' already exists, updating password."
else
    useradd -m -s /bin/bash "$TESTER_USER"
fi
echo "${TESTER_USER}:${TESTER_PASS}" | chpasswd

# Add tester to www-data group so they can write to the uploads directory
usermod -aG www-data "$TESTER_USER"

# Make sure the uploads directory is writable by www-data group members
chmod -R 775 "${WP_UPLOADS_PATH}"
chown -R www-data:www-data "${WP_UPLOADS_PATH}"

echo_success "Tester SSH user created."

# =============================================================================
# STEP 9: Firewall (UFW)
# =============================================================================
echo_info "Step 9/9: Configuring firewall..."

# NOTE: Oracle Cloud also has a Security List — see the guide for those steps.
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    # SSH
ufw allow 80/tcp    # HTTP (WordPress)
ufw allow 443/tcp   # HTTPS (future use)
ufw --force enable

echo_success "Firewall configured."

# =============================================================================
# Also open Oracle Cloud's iptables rules (Oracle adds its own rules)
# =============================================================================
# Oracle Cloud Ubuntu instances have iptables rules that block ports by default
iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
netfilter-persistent save 2>/dev/null || true

# =============================================================================
# Configure fail2ban for SSH protection
# =============================================================================
systemctl enable fail2ban
systemctl start fail2ban

# =============================================================================
# Final verification
# =============================================================================
echo_info "Verifying WordPress installation..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://${SERVER_IP}/")

if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "301" ] || [ "$HTTP_STATUS" = "302" ]; then
    WP_STATUS="${GREEN}✓ WordPress is reachable at http://${SERVER_IP}/${NC}"
else
    WP_STATUS="${RED}✗ Could not reach http://${SERVER_IP}/ (HTTP $HTTP_STATUS)${NC}"
    WP_STATUS="${WP_STATUS}\n   → Check Oracle Cloud Security List (port 80 must be open — see guide)"
fi

# =============================================================================
# PRINT CREDENTIALS SUMMARY
# =============================================================================
echo ""
echo "=============================================="
echo_success "SETUP COMPLETE! Save these credentials:"
echo "=============================================="
echo ""
echo -e "${YELLOW}--- WORDPRESS ADMIN ---${NC}"
echo "  URL:          http://${SERVER_IP}/wp-admin"
echo "  Username:     ${WP_ADMIN_USER}"
echo "  Password:     ${WP_ADMIN_PASS}"
echo "  Email:        ${WP_ADMIN_EMAIL}"
echo ""
echo -e "${YELLOW}--- SSH / RSYNC TESTER ACCESS ---${NC}"
echo "  Host:         ${SERVER_IP}"
echo "  Port:         22"
echo "  Username:     ${TESTER_USER}"
echo "  Password:     ${TESTER_PASS}"
echo "  Upload path:  ${WP_UPLOADS_PATH}"
echo ""
echo -e "${YELLOW}--- WORDPRESS SITE ---${NC}"
echo "  Site URL:     http://${SERVER_IP}/"
echo ""
echo -e "${YELLOW}--- DATABASE (for your records) ---${NC}"
echo "  DB Name:      ${WP_DB_NAME}"
echo "  DB User:      ${WP_DB_USER}"
echo "  DB Password:  ${WP_DB_PASS}"
echo ""
echo -e "WordPress status: $WP_STATUS"
echo ""
echo "=============================================="
echo " Next steps:"
echo "  1. Save all credentials above"
echo "  2. If WordPress isn't reachable, open port 80"
echo "     in Oracle Cloud Security List (see guide)"
echo "  3. Test SSH: ssh ${TESTER_USER}@${SERVER_IP}"
echo "  4. Test rsync: rsync -avz photo.jpg ${TESTER_USER}@${SERVER_IP}:${WP_UPLOADS_PATH}/"
echo "=============================================="
echo ""

# Save credentials to a file for easy reference
CREDS_FILE="/root/wordpress-credentials.txt"
cat > "$CREDS_FILE" << CREDSEOF
WordPress Setup Credentials — $(date)
======================================

WORDPRESS ADMIN
  URL:          http://${SERVER_IP}/wp-admin
  Username:     ${WP_ADMIN_USER}
  Password:     ${WP_ADMIN_PASS}
  Email:        ${WP_ADMIN_EMAIL}

SSH / RSYNC TESTER ACCESS
  Host:         ${SERVER_IP}
  Port:         22
  Username:     ${TESTER_USER}
  Password:     ${TESTER_PASS}
  Upload path:  ${WP_UPLOADS_PATH}

WORDPRESS SITE
  URL:          http://${SERVER_IP}/

DATABASE
  DB Name:      ${WP_DB_NAME}
  DB User:      ${WP_DB_USER}
  DB Password:  ${WP_DB_PASS}
CREDSEOF

echo_success "Credentials also saved to: $CREDS_FILE"
echo ""
