!
!//////////////////////////////////////////////////////
!
!   @File:    VariableConversion_iNS.f90
!   @Author:  Juan Manzanero (juan.manzanero@upm.es)
!   @Created: Tue Jun 19 17:39:27 2018
!   @Last revision date: Mon Jul  2 14:17:29 2018
!   @Last revision author: Juan Manzanero (juan.manzanero@upm.es)
!   @Last revision commit: 7af1f42fb2bc9ea3a0103412145f2a925b4fac5e
!
!//////////////////////////////////////////////////////
!
!
!//////////////////////////////////////////////////////
!
!
!//////////////////////////////////////////////////////
!
#include "Includes.h"
module VariableConversion_iNS
   use SMConstants
   use PhysicsStorage_iNS
   use FluidData_iNS
   implicit none

   private
   public   iNSGradientValuesForQ
   public   iNSGradientValuesForQ_0D, iNSGradientValuesForQ_3D
   public   GetiNSTwoFluidsViscosity, GetiNSOneFluidViscosity

   interface iNSGradientValuesForQ
       module procedure iNSGradientValuesForQ_0D , iNSGradientValuesForQ_3D
   end interface iNSGradientValuesForQ

   contains
!
! /////////////////////////////////////////////////////////////////////
!
!---------------------------------------------------------------------
!! GradientValuesForQ takes the solution (Q) values and returns the
!! quantities of which the gradients will be taken.
!---------------------------------------------------------------------
!
      pure subroutine iNSGradientValuesForQ_0D( nEqn, nGrad, Q, U )
         implicit none
         integer, intent(in)        :: nEqn, nGrad
         real(kind=RP), intent(in)  :: Q(nEqn)
         real(kind=RP), intent(out) :: U(nGrad)
!
!        ---------------
!        Local Variables
!        ---------------
!     
         U = Q

      end subroutine iNSGradientValuesForQ_0D

      pure subroutine iNSGradientValuesForQ_3D( nEqn, nGrad, Nx, Ny, Nz, Q, U )
         implicit none
         integer,       intent(in)  :: nEqn, nGrad, Nx, Ny, Nz
         real(kind=RP), intent(in)  :: Q(1:nEqn,  0:Nx, 0:Ny, 0:Nz)
         real(kind=RP), intent(out) :: U(1:nGrad, 0:Nx, 0:Ny, 0:Nz)

         U = Q

      end subroutine iNSGradientValuesForQ_3D

      pure subroutine GetiNSOneFluidViscosity(phi, mu)
!
!        ***********************************
!           Here phi is the density, such
!           that varies linearly from the
!           density of fluid 1 to that of
!           fluid 2
!        ***********************************
!
         implicit none
         real(kind=RP), intent(in)   :: phi
         real(kind=RP), intent(out)  :: mu
!
!        ---------------
!        Local variables
!        ---------------
!
         mu = dimensionless % mu(1)

      end subroutine GetiNSOneFluidViscosity

      pure subroutine GetiNSTwoFluidsViscosity(phi, mu)
!
!        ***********************************
!           Here phi is the density, such
!           that varies linearly from the
!           density of fluid 1 to that of
!           fluid 2
!        ***********************************
!
         implicit none
         real(kind=RP), intent(in)   :: phi
         real(kind=RP), intent(out)  :: mu
!
!        ---------------
!        Local variables
!        ---------------
!
         real(kind=RP)              :: mu2, mu1, rho1, rho2

         mu1 = dimensionless % mu(1)
         mu2 = dimensionless % mu(2)

         rho1 = dimensionless % rho(1)
         rho2 = dimensionless % rho(2)

         mu = mu1 * (phi - rho2)/(rho1-rho2) + mu2 * (phi-rho1)/(rho2-rho1)

      end subroutine GetiNSTwoFluidsViscosity
!
! /////////////////////////////////////////////////////////////////////
!
end module VariableConversion_iNS