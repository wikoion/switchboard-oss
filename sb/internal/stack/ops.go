package stack

import (
	"fmt"
	"strings"
)

// EnsureDatabases creates a role and database for Synapse and each enabled
// bridge, and resets their passwords to match secrets.env. Idempotent.
func (s *Stack) EnsureDatabases() error {
	type db struct{ name, secret string }
	dbs := []db{{"synapse", "SYNAPSE_DB_PASSWORD"}}
	enabled, err := s.Enabled()
	if err != nil {
		return err
	}
	for _, b := range enabled {
		dbs = append(dbs, db{b.ID, "DB_PASSWORD_" + strings.ToUpper(b.ID)})
	}
	var sql strings.Builder
	for _, d := range dbs {
		pw, err := s.Secrets.Get(d.secret)
		if err != nil {
			return err
		}
		fmt.Fprintf(&sql, "SELECT format('CREATE ROLE %%I LOGIN', '%[1]s') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '%[1]s')\\gexec\n", d.name)
		fmt.Fprintf(&sql, "ALTER ROLE %q PASSWORD '%s';\n", d.name, pw)
		fmt.Fprintf(&sql, "SELECT format('CREATE DATABASE %%I OWNER %%I ENCODING ''UTF8'' LC_COLLATE ''C'' LC_CTYPE ''C'' TEMPLATE template0', '%[1]s', '%[1]s') WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '%[1]s')\\gexec\n", d.name)
	}
	out, err := s.ComposeOutput(sql.String(), "exec", "-T", "postgres", "psql", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-q", "-f", "-")
	if err != nil {
		return fmt.Errorf("creating databases: %w\n%s", err, out)
	}
	return nil
}

// CreateAdmin registers the owner account through Synapse's shared-secret
// registration. An existing account is left alone.
func (s *Stack) CreateAdmin() error {
	pw, err := s.Secrets.Get("ADMIN_PASSWORD")
	if err != nil {
		return err
	}
	out, err := s.ComposeOutput("", "exec", "-T", "synapse", "register_new_matrix_user",
		"-u", s.Settings.Owner, "-p", pw, "-a", "-c", "/data/config/homeserver.yaml", "http://localhost:8008")
	if err != nil && !strings.Contains(out, "User ID already taken") {
		return fmt.Errorf("creating admin user: %w\n%s", err, out)
	}
	return nil
}
