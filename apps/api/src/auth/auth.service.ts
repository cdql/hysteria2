import {
  BadRequestException,
  Injectable,
  Logger,
  UnauthorizedException,
} from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { compare, hash } from 'bcryptjs';
import { CacheService } from '../cache/cache.service';
import { type SessionPrincipal } from '../common/auth.types';
import { webPublicUrl } from '../common/public-url';
import { ControlPlaneStoreService } from '../domain/control-plane.store';
import { MailService } from '../mail/mail.service';

const PASSWORD_RESET_COOLDOWN_SECONDS = 60;
const PASSWORD_RESET_RESPONSE = {
  success: true,
  message: '如果该邮箱已开通账户，重置链接将在几分钟内发送。',
} as const;

@Injectable()
export class AuthService {
  private readonly logger = new Logger(AuthService.name);

  constructor(
    private readonly store: ControlPlaneStoreService,
    private readonly jwtService: JwtService,
    private readonly cache: CacheService,
    private readonly mail: MailService,
  ) {}

  async login(email: string, password: string) {
    const normalizedEmail = this.normalizeEmail(email);
    const user = await this.store.findUserByEmail(normalizedEmail);
    if (!user) {
      throw new UnauthorizedException('Invalid credentials');
    }

    const isValid = await compare(password, user.passwordHash);
    if (!isValid) {
      throw new UnauthorizedException('Invalid credentials');
    }
    if (user.status !== 'active') {
      throw new UnauthorizedException('Account is not active');
    }

    return this.issueSession(user);
  }

  async oauthLogin(input: { email: string; displayName: string }) {
    const email = this.normalizeEmail(input.email);

    // Self-service registration is removed: accounts are created by
    // administrators only, so third-party login works for existing users.
    const user = await this.store.findUserByEmail(email);
    if (!user) {
      throw new BadRequestException('该邮箱尚未开通账户，请联系管理员');
    }
    if (user.status !== 'active') {
      throw new UnauthorizedException('Account is not active');
    }

    return this.issueSession(user);
  }

  async logout(jti: string) {
    await this.cache.del(`session:${jti}`);
    return { success: true };
  }

  async issuePasswordReset(userId: string, createdById: string) {
    return this.createPasswordReset(userId, createdById);
  }

  async requestPasswordReset(rawEmail: string) {
    const email = this.normalizeEmail(rawEmail);
    const cooldownKey = `password-reset-cooldown:${email}`;
    if (await this.cache.get(cooldownKey)) return PASSWORD_RESET_RESPONSE;

    await this.cache.set(cooldownKey, '1', PASSWORD_RESET_COOLDOWN_SECONDS);
    const user = await this.store.findUserByEmail(email);
    if (!user || user.status !== 'active') return PASSWORD_RESET_RESPONSE;

    const reset = await this.createPasswordReset(user.id, null);
    try {
      await this.mail.sendPasswordReset(email, reset.resetUrl);
    } catch (error) {
      this.logger.error(
        `Password reset email failed for user ${user.id}`,
        error instanceof Error ? error.stack : String(error),
      );
    }
    return PASSWORD_RESET_RESPONSE;
  }

  private async createPasswordReset(
    userId: string,
    createdById: string | null,
  ) {
    const rawToken = randomBytes(32).toString('base64url');
    const tokenHash = this.hashResetToken(rawToken);
    const expiresAt = new Date(Date.now() + 30 * 60 * 1000);
    await this.store.issuePasswordResetToken({
      userId,
      createdById,
      tokenHash,
      expiresAt,
    });
    return {
      resetUrl: `${webPublicUrl()}/reset-password?token=${encodeURIComponent(rawToken)}`,
      expiresAt: expiresAt.toISOString(),
    };
  }

  async resetPassword(rawToken: string, password: string) {
    const passwordHash = await hash(password, 10);
    const consumed = await this.store.consumePasswordResetToken(
      this.hashResetToken(rawToken),
      passwordHash,
    );
    if (!consumed) {
      throw new BadRequestException('Reset link is invalid or expired');
    }
    return { success: true };
  }

  async me(userId: string) {
    const user = await this.store.getUserById(userId);
    if (!user) {
      throw new UnauthorizedException('Unknown session subject');
    }

    if (user.status !== 'active') {
      throw new UnauthorizedException('Account is not active');
    }
    const safeUser = this.publicUser(user);
    return {
      user: safeUser,
      role: user.role,
      scope: user.role === 'admin' ? 'admin' : 'portal',
    };
  }

  private async issueSession(user: {
    id: string;
    role: 'admin' | 'member';
    status: 'active' | 'suspended' | 'banned';
    email: string;
    displayName: string;
    passwordHash: string;
    sessionVersion: number;
  }) {
    if (user.status !== 'active') {
      throw new UnauthorizedException('Account is not active');
    }
    const principal: SessionPrincipal = {
      sub: user.id,
      role: user.role,
      email: user.email,
      displayName: user.displayName,
      jti: randomUUID(),
      sessionVersion: user.sessionVersion,
    };

    const accessToken = await this.jwtService.signAsync(principal, {
      secret: process.env.JWT_SECRET,
      expiresIn: '12h',
    });

    await this.cache.set(
      `session:${principal.jti}`,
      JSON.stringify(principal),
      12 * 60 * 60,
    );

    const safeUser = this.publicUser(user);
    return {
      accessToken,
      principal,
      user: safeUser,
    };
  }

  private publicUser<T extends { passwordHash?: string }>(
    user: T,
  ): Omit<T, 'passwordHash'> {
    const { passwordHash, ...safeUser } = user;
    void passwordHash;
    return safeUser;
  }

  private normalizeEmail(email: string) {
    return email.trim().toLowerCase();
  }

  private hashResetToken(token: string) {
    return createHash('sha256').update(token).digest('hex');
  }
}
