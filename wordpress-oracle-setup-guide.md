# WordPress Oracle Cloud Setup Guide
### For Apple App Store Review Testing

---

## Overview

This guide walks you through getting a fresh Oracle Cloud Ubuntu instance fully running with WordPress, WP-CLI, and SSH/rsync access for the Apple App Store reviewer. There are three main phases:

1. **Get SSH access** to your Oracle Cloud server
2. **Open ports** in Oracle Cloud's firewall (two layers — easy to miss)
3. **Run the setup script** that installs everything automatically

Total time: about 15–20 minutes.

---

## Phase 1: Get Your Server's IP and SSH Access

### 1.1 Find your server IP

1. Go to [cloud.oracle.com](https://cloud.oracle.com) and log in
2. Navigate to **Compute → Instances**
3. Click your instance name
4. Copy the **Public IP address** (looks like `152.70.xxx.xxx`)

You'll need this IP in the setup script.

### 1.2 Find your SSH key

Oracle Cloud creates a key pair when you launch an instance. When you created the instance, you either:
- **Downloaded a private key** (a `.key` file) — you should have this saved somewhere
- **Used an existing key pair** — use that key

If you can't find your private key, you'll need to either recreate the instance or add a new key via the Oracle Cloud console (Instance Details → Resources → Console Connection).

### 1.3 Test SSH access

Open Terminal on your Mac and run:

```bash
ssh -i /path/to/your-key.key ubuntu@YOUR_SERVER_IP
```

> **Note:** The default username on Oracle Cloud Ubuntu is `ubuntu`, not `root`.

If it connects, you're in. If you get a permission error on the key file, run:

```bash
chmod 400 /path/to/your-key.key
```

---

## Phase 2: Open Ports in Oracle Cloud (Critical — Easy to Miss)

Oracle Cloud has **two separate firewall layers**. Both must be opened for WordPress to be reachable from the internet.

### Layer 1: Oracle Cloud Security List (the outer firewall)

1. In the Oracle Cloud Console, go to **Networking → Virtual Cloud Networks**
2. Click your VCN (usually named `vcn-...`)
3. Click **Security Lists** in the left sidebar
4. Click **Default Security List**
5. Click **Add Ingress Rules**
6. Add these two rules:

**Rule 1 — HTTP:**
- Source CIDR: `0.0.0.0/0`
- IP Protocol: `TCP`
- Destination Port Range: `80`

**Rule 2 — HTTPS (optional but good to have):**
- Source CIDR: `0.0.0.0/0`
- IP Protocol: `TCP`
- Destination Port Range: `443`

7. Click **Add Ingress Rules** to save.

> SSH (port 22) should already be open by default.

### Layer 2: iptables (the inner firewall — Oracle-specific)

Oracle Cloud Ubuntu instances have a second layer of iptables rules that block ports even after you open them in the Security List. The setup script handles this automatically, but here's what it does for reference:

```bash
iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
netfilter-persistent save
```

This is run automatically by the setup script, so you don't need to do it manually.

---

## Phase 3: Run the Setup Script

### 3.1 Upload the script to your server

From your Mac's Terminal (in the same folder as the script):

```bash
scp -i /path/to/your-key.key wordpress-oracle-setup.sh ubuntu@YOUR_SERVER_IP:~/
```

### 3.2 Edit the script with your IP address

SSH into your server:

```bash
ssh -i /path/to/your-key.key ubuntu@YOUR_SERVER_IP
```

Then edit the script to add your IP:

```bash
nano wordpress-oracle-setup.sh
```

Find this line near the top:
```bash
SERVER_IP="YOUR_SERVER_IP_HERE"
```

Replace `YOUR_SERVER_IP_HERE` with your actual IP address (e.g., `152.70.123.45`).

You can also optionally change:
- `WP_ADMIN_EMAIL` — your email address
- `WP_SITE_TITLE` — the name of the test site

Save with `Ctrl+O`, then `Enter`, then `Ctrl+X`.

### 3.3 Run the script

```bash
sudo bash wordpress-oracle-setup.sh
```

The script will take 5–10 minutes. When it finishes, it prints all credentials and also saves them to `/root/wordpress-credentials.txt`.

**Important:** Copy and save the credentials that are printed at the end before you close the terminal.

---

## Phase 4: Verify Everything Works

### 4.1 Test the WordPress site

Open a browser and go to:
```
http://YOUR_SERVER_IP/
```

You should see the WordPress homepage.

### 4.2 Test WordPress admin

Go to:
```
http://YOUR_SERVER_IP/wp-admin
```

Log in with the `admin` username and password from the script output.

### 4.3 Test SSH access for the tester user

From your Mac's Terminal:

```bash
ssh tester@YOUR_SERVER_IP
```

Enter the tester password when prompted. You should get a shell prompt.

### 4.4 Test rsync upload (simulate what the app does)

```bash
rsync -avz --progress /path/to/test-photo.jpg tester@YOUR_SERVER_IP:/var/www/html/wp-content/uploads/
```

Then go to `http://YOUR_SERVER_IP/wp-admin/upload.php` to confirm the photo appears in the Media Library.

---

## What the Setup Script Installs

| Component | Details |
|-----------|---------|
| **Apache** | Web server, with mod_rewrite enabled for WordPress permalinks |
| **PHP** | Latest available, with all WordPress-required extensions |
| **MySQL** | Database server, secured, with WordPress database created |
| **WordPress** | Latest version, fully installed and configured |
| **WP-CLI** | Installed at `/usr/local/bin/wp`, usable by all users |
| **rsync** | Pre-installed for the app's file transfer |
| **fail2ban** | Blocks brute-force SSH attacks |
| **UFW** | Firewall: allows SSH (22), HTTP (80), HTTPS (443) |

---

## Credentials Summary (fill in after running the script)

After running the script, save these here for easy reference:

```
SERVER IP:          _______________________

WORDPRESS ADMIN:
  URL:              http://_______________/wp-admin
  Username:         admin
  Password:         _______________________

TESTER SSH USER:
  Host:             _______________________
  Port:             22
  Username:         tester
  Password:         _______________________
  Upload path:      /var/www/html/wp-content/uploads

WORDPRESS SITE:
  URL:              http://_______________/
```

---

## What to Send the Apple Reviewer

Once everything is set up, send the reviewer:

1. **A test photo** (a sample .jpg to upload)
2. **SSH credentials:** hostname (your IP), username (`tester`), password
3. **Upload path:** `/var/www/html/wp-content/uploads`
4. **WordPress URL** to verify the photo appears: `http://YOUR_IP/wp-admin/upload.php`
5. **WordPress admin credentials** (in case they need to verify in the dashboard)

See the `apple-reviewer-instructions.md` file for a ready-to-send message.

---

## Troubleshooting

### WordPress isn't reachable at my IP

1. Double-check that port 80 is open in the Oracle Cloud **Security List** (Phase 2, Layer 1)
2. SSH into the server and run: `sudo systemctl status apache2` — it should say "active (running)"
3. Check iptables: `sudo iptables -L INPUT -n | grep 80` — you should see an ACCEPT rule

### SSH connection refused or times out

- Make sure port 22 is open in the Oracle Cloud Security List
- Try: `ssh -v ubuntu@YOUR_IP` to see verbose connection details

### rsync: Permission denied on the uploads folder

SSH into the server and run:
```bash
sudo chown -R www-data:www-data /var/www/html/wp-content/uploads
sudo chmod -R 775 /var/www/html/wp-content/uploads
sudo usermod -aG www-data tester
```
Then log out and back in as the tester user.

### Photo uploaded via rsync but doesn't show in Media Library

WordPress's Media Library only shows files it knows about in the database. Use WP-CLI to import uploaded files:

```bash
sudo -u www-data wp media import /var/www/html/wp-content/uploads/*.jpg --path=/var/www/html
```

Or the reviewer can use your app's import feature if it triggers a WP REST API call to register the media.

### WP-CLI not working

```bash
wp --info
```
Should print WP-CLI version info. If command not found:
```bash
sudo curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
sudo chmod +x wp-cli.phar
sudo mv wp-cli.phar /usr/local/bin/wp
```

---

## Security Notes

This is a **test server** — the configuration prioritizes ease of access for the reviewer over long-term security hardening. Once App Store review is complete, either:
- Delete the Oracle Cloud instance (free tier instances are easy to recreate), or
- Change the tester password: `sudo passwd tester`
- Disable password SSH auth: edit `/etc/ssh/sshd_config` and set `PasswordAuthentication no`
