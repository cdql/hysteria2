"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { FormEvent, useEffect, useState } from "react";
import { ApiError } from "@/lib/api";
import { useAuth } from "./auth-provider";
import { AuthShell } from "./auth-shell";
import { Icon } from "./icon";
import { OAuthButtons } from "./oauth-buttons";

export function AuthExperience() {
  const { session, login, loading } = useAuth();
  const router = useRouter();
  const [loginEmail, setLoginEmail] = useState("");
  const [loginPassword, setLoginPassword] = useState("");
  const [loginSubmitting, setLoginSubmitting] = useState(false);
  const [loginError, setLoginError] = useState<string | null>(null);
  const [oauthError, setOauthError] = useState<string | null>(null);
  const [loginNext, setLoginNext] = useState<string | null>(null);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      const params = new URLSearchParams(window.location.search);
      setLoginNext(params.get("next"));
      setOauthError(params.get("oauth_error"));
    }, 0);
    return () => window.clearTimeout(timer);
  }, []);

  useEffect(() => {
    if (!loading && session) {
      router.replace(session.role === "admin" ? "/admin" : "/portal");
    }
  }, [loading, router, session]);

  async function handleLogin(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setLoginSubmitting(true);
    setLoginError(null);
    try {
      const nextSession = await login(loginEmail, loginPassword);
      router.replace(
        loginNext || (nextSession.role === "admin" ? "/admin" : "/portal"),
      );
    } catch (cause) {
      if (cause instanceof ApiError && cause.status === 401) {
        setLoginError("邮箱或密码错误，请检查后重新输入。");
      } else {
        setLoginError(
          cause instanceof ApiError ? cause.message : "登录失败，请稍后重试。",
        );
      }
    } finally {
      setLoginSubmitting(false);
    }
  }

  return (
    <AuthShell active="login">
      <div className="auth2-view" key="login">
        <form className="auth2-fields" onSubmit={handleLogin}>
          <div className="auth2-field-stack">
            <label className="auth2-input">
              <span className="auth2-input-icon">
                <Icon name="mail" />
              </span>
              <span className="auth2-field-body">
                <span className="auth2-field-label">邮箱地址</span>
                <input
                  aria-describedby={loginError ? "login-error" : undefined}
                  aria-invalid={Boolean(loginError)}
                  type="email"
                  value={loginEmail}
                  onChange={(event) => setLoginEmail(event.target.value)}
                  placeholder="邮箱地址"
                  autoComplete="username"
                  required
                />
              </span>
            </label>
            <label className="auth2-input">
              <span className="auth2-input-icon">
                <Icon name="lock" />
              </span>
              <span className="auth2-field-body">
                <span className="auth2-field-label">登录密码</span>
                <input
                  aria-describedby={loginError ? "login-error" : undefined}
                  aria-invalid={Boolean(loginError)}
                  type="password"
                  value={loginPassword}
                  onChange={(event) => setLoginPassword(event.target.value)}
                  placeholder="登录密码"
                  autoComplete="current-password"
                  required
                />
              </span>
            </label>
          </div>

          {loginError ? (
            <div
              className="feedback error auth2-login-error"
              id="login-error"
              role="alert"
            >
              {loginError}
            </div>
          ) : null}
          {oauthError ? (
            <div className="feedback error" role="alert">
              {oauthError}
            </div>
          ) : null}

          <div className="auth2-row">
            <span />
            <Link
              className="auth2-link"
              href={`/forgot-password?email=${encodeURIComponent(loginEmail)}`}
            >
              忘记密码？
            </Link>
          </div>

          <button
            className="auth2-submit"
            type="submit"
            disabled={loginSubmitting}
          >
            <span>{loginSubmitting ? "登录中..." : "登录"}</span>
            <Icon name="login" />
          </button>
        </form>
      </div>

      <OAuthButtons />
    </AuthShell>
  );
}
