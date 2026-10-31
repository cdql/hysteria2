import { Module } from '@nestjs/common';
import { ReferralService } from './referral.service';
import {
  AdminReferralController,
  PortalReferralController,
} from './referral.controller';
import { EntitlementModule } from '../entitlement/entitlement.module';

@Module({
  imports: [EntitlementModule],
  controllers: [PortalReferralController, AdminReferralController],
  providers: [ReferralService],
  exports: [ReferralService],
})
export class ReferralModule {}
