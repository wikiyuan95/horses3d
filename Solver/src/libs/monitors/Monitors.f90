!
!///////////////////////////////////////////////////////////////////////////////////////////////////////
!
!    HORSES2D - A high-order discontinuous Galerkin spectral element solver.
!    Copyright (C) 2017  Juan Manzanero Torrico (juan.manzanero@upm.es)
!
!    This program is free software: you can redistribute it and/or modify
!    it under the terms of the GNU General Public License as published by
!    the Free Software Foundation, either version 3 of the License, or
!    (at your option) any later version.
!
!    This program is distributed in the hope that it will be useful,
!    but WITHOUT ANY WARRANTY; without even the implied warranty of
!    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
!    GNU General Public License for more details.
!
!    You should have received a copy of the GNU General Public License
!    along with this program.  If not, see <http://www.gnu.org/licenses/>.
!
!////////////////////////////////////////////////////////////////////////////////////////////////////////
!
!
!///////////////////////////////////////////////////////////////////////////////////////////////////
!
!        Monitors.f90
!
!///////////////////////////////////////////////////////////////////////////////////////////////////
!
module MonitorsClass
   use SMConstants
   use HexMeshClass
   use MonitorDefinitions
   use ResidualsMonitorClass
   use StatisticsMonitor
   use SurfaceMonitorClass
   use VolumeMonitorClass
   implicit none
!
#include "Includes.h"

   private
   public      Monitor_t , ConstructMonitors
!
!  *********************************************************************
!
!  *********************************************************************
!
!   type Probe_t
!      logical                         :: active
!      integer                         :: ID
!      integer                         :: eID
!      real(kind=RP)                   :: x(NDIM)
!      real(kind=RP)                   :: xi, eta
!      real(kind=RP)                   :: values(BUFFER_SIZE)
!      real(kind=RP), allocatable      :: l_xi(:) , l_eta(:)
!      character(len=STR_LEN_MONITORS) :: fileName
!      character(len=STR_LEN_MONITORS) :: monitorName
!      character(len=STR_LEN_MONITORS) :: variable
!      contains
!         procedure   :: Initialization => Probe_Initialization
!         procedure   :: Update         => Probe_Update
!         procedure   :: WriteLabel     => Probe_WriteLabel
!         procedure   :: WriteValues    => Probe_WriteValue
!         procedure   :: WriteToFile    => Probe_WriteToFile
!   end type Probe_t
!
!  *****************************
!  Main monitor class definition
!  *****************************
!  
   type Monitor_t
      character(len=LINE_LENGTH)           :: solution_file
      integer                              :: no_of_surfaceMonitors
      integer                              :: no_of_volumeMonitors
      integer                              :: bufferLine
      integer                              :: iter( BUFFER_SIZE )
      real(kind=RP)                        :: t  (BUFFER_SIZE )
      type(StatisticsMonitor_t)            :: stats
      type(Residuals_t)                    :: residuals
      class(SurfaceMonitor_t), allocatable :: surfaceMonitors(:)
      class(VolumeMonitor_t),  allocatable :: volumeMonitors(:)
      contains
         procedure   :: WriteLabel      => Monitor_WriteLabel
         procedure   :: WriteUnderlines => Monitor_WriteUnderlines
         procedure   :: WriteValues     => Monitor_WriteValues
         procedure   :: UpdateValues    => Monitor_UpdateValues
         procedure   :: WriteToFile     => Monitor_WriteToFile
   end type Monitor_t
!
!  ========
   contains
!  ========
!
!///////////////////////////////////////////////////////////////////////////////////////
!
      function ConstructMonitors( mesh, controlVariables ) result(Monitors)
         use FTValueDictionaryClass
         use mainKeywordsModule
         implicit none
         class(HexMesh), intent(in)           :: mesh
         class(FTValueDictionary), intent(in) :: controlVariables
         type(Monitor_t)                      :: Monitors
!
!        ---------------
!        Local variables
!        ---------------
!
         integer                         :: fID , io
         integer                         :: i
         character(len=STR_LEN_MONITORS) :: line
         character(len=STR_LEN_MONITORS) :: solution_file                                            
         interface
            character(len=LINE_LENGTH) function getFileName(inputLine)
               use SMConstants
               character(len=*)   :: inputLine
            end function getFileName
         end interface
!
!        Get the solution file name
!        --------------------------
         solution_file = controlVariables % stringValueForKey( solutionFileNameKey, requestedLength = STR_LEN_MONITORS )
!
!        Remove the *.hsol termination
!        -----------------------------
         solution_file = trim(getFileName(solution_file))
         Monitors % solution_file = trim(solution_file)
!
!        Search in case file for probes, surface monitors, and volume monitors
!        ---------------------------------------------------------------------
         call getNoOfMonitors( Monitors % no_of_surfaceMonitors, Monitors % no_of_volumeMonitors )
!
!        Initialize
!        ----------
         call Monitors % stats     % Construct(mesh)
         call Monitors % residuals % Initialization( solution_file )

         allocate ( Monitors % surfaceMonitors ( Monitors % no_of_surfaceMonitors )  )
         do i = 1 , Monitors % no_of_surfaceMonitors
            call Monitors % surfaceMonitors(i) % Initialization ( mesh , i, solution_file )
         end do

         allocate ( Monitors % volumeMonitors ( Monitors % no_of_volumeMonitors )  )
         do i = 1 , Monitors % no_of_volumeMonitors
            call Monitors % volumeMonitors(i) % Initialization ( mesh , i, solution_file )
         end do


         Monitors % bufferLine = 0

      end function ConstructMonitors

      subroutine Monitor_WriteLabel ( self )
!
!        ***************************************************
!           This subroutine prints the labels for the time
!         integrator Display procedure.
!        ***************************************************
!
         implicit none
         class(Monitor_t)              :: self
         integer                       :: i 
!
!        Write "Iteration" and "Time"
!        ----------------------------
         write ( STD_OUT , ' ( A10    ) ' , advance = "no" ) "Iteration"
         write ( STD_OUT , ' ( 3X,A10 ) ' , advance = "no" ) "Time"
!
!        Write residuals labels
!        ----------------------
         call self % residuals % WriteLabel
!
!        Write surface monitors labels
!        -----------------------------
         do i = 1 , self % no_of_surfaceMonitors
            call self % surfaceMonitors(i) % WriteLabel
         end do
!
!        Write volume monitors labels
!        -----------------------------
         do i = 1 , self % no_of_volumeMonitors
            call self % volumeMonitors(i) % WriteLabel
         end do

         call self % stats % WriteLabel

         write(STD_OUT , *) 

      end subroutine Monitor_WriteLabel

      subroutine Monitor_WriteUnderlines( self ) 
!
!        ********************************************************
!              This subroutine displays the underlines for the
!           time integrator Display procedure.
!        ********************************************************
!
         use PhysicsStorage
         implicit none
         class(Monitor_t)                         :: self
!
!        ---------------
!        Local variables
!        ---------------
!
         integer                                  :: i
         character(len=MONITOR_LENGTH), parameter :: dashes = "----------"
!
!        Print dashes for "Iteration" and "Time"
!        ---------------------------------------
         write ( STD_OUT , ' ( A10    ) ' , advance = "no" ) trim ( dashes ) 
         write ( STD_OUT , ' ( 3X,A10 ) ' , advance = "no" ) trim ( dashes ) 
!
!        Print dashes for residuals
!        --------------------------
         do i = 1 , NCONS
            write(STD_OUT , '(3X,A10)' , advance = "no" ) trim(dashes)
         end do
!
!        Print dashes for surface monitors
!        ---------------------------------
         do i = 1 , self % no_of_surfaceMonitors
            write(STD_OUT , '(3X,A10)' , advance = "no" ) dashes(1 : min(10 , len_trim( self % surfaceMonitors(i) % monitorName ) + 2 ) )
         end do
!!
!!        Print dashes for probes
!!        -----------------------
!         do i = 1 , self % no_of_probes
!            if ( self % probes(i) % active ) then
!               write(STD_OUT , '(3X,A10)' , advance = "no" ) dashes(1 : min(10 , len_trim( self % probes(i) % monitorName ) + 2 ) )
!            end if
!         end do
!
!        Print dashes for volume monitors
!        --------------------------------
         do i = 1 , self % no_of_volumeMonitors
            write(STD_OUT , '(3X,A10)' , advance = "no" ) dashes(1 : min(10 , len_trim( self % volumeMonitors(i) % monitorName ) + 2 ) )
         end do

         if ( self % stats % state .ne. 0 ) write(STD_OUT,'(3X,A10)',advance="no") trim(dashes)

         write(STD_OUT , *) 

      end subroutine Monitor_WriteUnderlines

      subroutine Monitor_WriteValues ( self )
!
!        *******************************************************
!              This subroutine prints the values for the time
!           integrator Display procedure.
!        *******************************************************
!
         implicit none
         class(Monitor_t)           :: self
         integer                    :: i
!
!        Print iteration and time
!        ------------------------
         write ( STD_OUT , ' ( I10            ) ' , advance = "no" ) self % iter    ( self % bufferLine ) 
         write ( STD_OUT , ' ( 1X,A,1X,ES10.3 ) ' , advance = "no" ) "|" , self % t ( self % bufferLine ) 
!
!        Print residuals
!        ---------------
         call self % residuals % WriteValues( self % bufferLine )
!
!        Print surface monitors
!        ----------------------
         do i = 1 , self % no_of_surfaceMonitors
            call self % surfaceMonitors(i) % WriteValues ( self % bufferLine )
         end do
!!
!!        Print probes
!!        ------------
!         do i = 1 , self % no_of_probes
!            call self % probes(i) % WriteValues ( self % bufferLine )
!         end do
!
!        Print volume monitors
!        ---------------------
         do i = 1 , self % no_of_volumeMonitors
            call self % volumeMonitors(i) % WriteValues ( self % bufferLine )
         end do

         call self % stats % WriteValue

         write(STD_OUT , *) 

      end subroutine Monitor_WriteValues

      subroutine Monitor_UpdateValues ( self, mesh, spA, t , iter, maxResiduals )
!
!        ***************************************************************
!              This subroutine updates the values for the residuals,
!           for the probes, surface and volume monitors.
!        ***************************************************************
!        
         use PhysicsStorage
         implicit none
         class(Monitor_t) :: self
         class(HexMesh)   :: mesh
         class(NodalStorage)  :: spA(0:,0:,0:)
         real(kind=RP)    :: t
         integer          :: iter
         real(kind=RP)    :: maxResiduals(NCONS)
!
!        ---------------
!        Local variables
!        ---------------
!
         integer                       :: i 
!
!        Move to next buffer line
!        ------------------------
         self % bufferLine = self % bufferLine + 1
!
!        Save time and iteration
!        -----------------------
         self % t    ( self % bufferLine )  = t
         self % iter ( self % bufferLine )  = iter
!!
!        Compute current residuals
!        -------------------------
         call self % residuals % Update( mesh, maxResiduals, self % bufferLine )
!
!        Update surface monitors
!        -----------------------
         do i = 1 , self % no_of_surfaceMonitors
            call self % surfaceMonitors(i) % Update( mesh , spA, self % bufferLine )
         end do

!!
!!        Update probes
!!        -------------
!         do i = 1 , self % no_of_probes
!            call self % probes(i) % Update( mesh , self % bufferLine )
!         end do
!
!        Update volume monitors
!        ----------------------
         do i = 1 , self % no_of_volumeMonitors
            call self % volumeMonitors(i) % Update( mesh , spA, self % bufferLine )
         end do
!
!        Update statistics
!        -----------------
         call self % stats % Update(mesh, iter, t, trim(self % solution_file) )

      end subroutine Monitor_UpdateValues

      subroutine Monitor_WriteToFile ( self , mesh, force) 
!
!        ******************************************************************
!              This routine has a double behaviour:
!           force = .true.  -> Writes to file and resets buffers
!           force = .false. -> Just writes to file if the buffer is full
!        ******************************************************************
!
         implicit none
         class(Monitor_t)        :: self
         class(HexMesh)          :: mesh
         logical, optional       :: force
!        ------------------------------------------------
         integer                 :: i 
         logical                 :: forceVal

         if ( present ( force ) ) then
            forceVal = force

         else
            forceVal = .false.

         end if

         if ( forceVal ) then 
!
!           In this case the monitors are exported to their files and the buffer is reseted
!           -------------------------------------------------------------------------------
            call self % residuals % WriteToFile ( self % iter , self % t , self % bufferLine )

            do i = 1 , self % no_of_surfaceMonitors
               call self % surfaceMonitors(i) % WriteToFile ( self % iter , self % t , self % bufferLine )
            end do

!            do i = 1 , self % no_of_probes
!               call self % probes(i) % WriteToFile ( self % iter , self % t , self % bufferLine )
!            end do

            do i = 1 , self % no_of_volumeMonitors
               call self % volumeMonitors(i) % WriteToFile ( self % iter , self % t , self % bufferLine )
            end do
!
!           Write statistics
!           ----------------
            if ( self % bufferLine .eq. 0 ) then
               i = 1
            else
               i = self % bufferLine
            end if
            call self % stats % WriteFile(mesh, self % iter(i), self % t(i), self % solution_file)
!
!           Reset buffer
!           ------------
            self % bufferLine = 0


         else
!
!           The monitors are exported just if the buffer is full
!           ----------------------------------------------------
            if ( self % bufferLine .eq. BUFFER_SIZE ) then

               call self % residuals % WriteToFile ( self % iter , self % t , BUFFER_SIZE )

               do i = 1 , self % no_of_surfaceMonitors
                  call self % surfaceMonitors(i) % WriteToFile ( self % iter , self % t , self % bufferLine )
               end do

!               do i = 1 , self % no_of_probes
!                  call self % probes(i) % WriteToFile ( self % iter , self % t , BUFFER_SIZE ) 
!               end do
!
               do i = 1 , self % no_of_volumeMonitors
                  call self % volumeMonitors(i) % WriteToFile ( self % iter , self % t , self % bufferLine )
               end do

               self % bufferLine = 0
   
            end if
         end if

      end subroutine Monitor_WriteToFile
!!
!!//////////////////////////////////////////////////////////////////////////////////////////////////
!!
!!           PROBE ROUTINES
!!           --------------
!!//////////////////////////////////////////////////////////////////////////////////////////////////
!!
!      subroutine Probe_Initialization( self , mesh , ID ) 
!!
!!        **********************************************************
!!              This subroutine initializes the probe.
!!           Reads from the case file the following variables needed:
!!              -> Name: The probe name (max 10 characters)
!!              -> x position: The x coordinate of the probe
!!              -> y position: The y coordinate of the probe
!!              -> variable: The name of the variable to be tracked
!!           Then, the element which contains the probe and its position
!!           in the reference element is computed. If any trouble occurs,
!!           the parameter "active" is set to .false.
!!        **********************************************************
!!
!         use MatrixOperations
!         implicit none
!         class(Probe_t)          :: self
!         class(HexMesh)          :: mesh
!         integer                 :: ID
!!
!!        ---------------
!!        Local variables
!!        ---------------
!!
!         character(len=STR_LEN_MONITORS)  :: in_label
!         character(len=STR_LEN_MONITORS)  :: fileName
!         real(kind=RP), allocatable       :: x,y
!         integer                          :: pos
!         integer                          :: fID
!         real(kind=RP)                    :: coords(NDIM)
!!!
!!!        Probe ID
!!!        --------
!!         self % ID = ID
!!!
!!!        Label to search for the probe data in the file
!!!        ----------------------------------------------
!!         write(in_label , '(A,I0)') "#define probe " , self % ID
!!         
!!         call readValueInRegion ( trim ( Setup % case_file )  , "Name"       , self % monitorName , in_label , "# end" ) 
!!         call readValueInRegion ( trim ( Setup % case_file )  , "x position" , x                  , in_label , "# end" ) 
!!         call readValueInRegion ( trim ( Setup % case_file )  , "Variable"   , self % variable    , in_label , "# end" ) 
!!         call readValueInRegion ( trim ( Setup % case_file )  , "y position" , y                  , in_label , "# end" ) 
!!!
!!!        Find for the element in the mesh, and the position in the reference element, that contains the probe
!!!        ----------------------------------------------------------------------------------------------------
!!         coords = [x,y]
!!         call mesh % findElementWithCoords(coords , self % eID , self % xi , self % eta )
!!!
!!!        In case is not found, the active parameter is set to false
!!!        ----------------------------------------------------------
!!         if ( self % eID .eq. -1 ) then
!!            self % active = .false.
!!            return
!!
!!         else
!!            self % active = .true.
!!
!!         end if
!!!
!!!        Compute the Lagrange interpolants for the probe position
!!!        --------------------------------------------------------
!!         self % l_xi  = mesh % elements(self % eID) % spA % lj( self % xi  )
!!         self % l_eta = mesh % elements(self % eID) % spA % lj( self % eta )
!!!
!!!        Obtain the real coordinates: this will be the ones used
!!!        -------------------------------------------------------
!!         self % x = [ BilinearForm_F ( mesh % elements(self % eID) % X(:,:,IX) , self % l_xi , self % l_eta ) , &
!!                      BilinearForm_F ( mesh % elements(self % eID) % X(:,:,IY) , self % l_xi , self % l_eta ) ]
!!!
!!!        Get the monitor file name
!!!        -------------------------
!!         write( self % fileName , '(A,A,A,A)') trim(Setup % solution_file) , "." , trim(self % monitorName) , ".probe"  
!!!
!!!        Create file
!!!        -----------
!!         open ( newunit = fID , file = trim(self % fileName) , status = "unknown" , action = "write" ) 
!!!
!!!        Set its header
!!!        --------------
!!         write( fID , '(A20,A    )') "Probe name :       " , trim(self % monitorName)
!!         write( fID , '(A20,F10.3)') "x position :       " , self % x(IX) 
!!         write( fID , '(A20,F10.3)') "y position :       " , self % x(IY) 
!!         write( fID , '(A20,I10  )') "Element    :       " , self % eID
!!         write( fID , '(A20,A    )') "Tracked variable : " , trim( self % variable )
!!         write( fID , * )
!!!
!!!        Write "iteration", "time", and the label of the variable
!!!        --------------------------------------------------------
!!         write( fID , '(A10,2X,A24,2X,A24)' ) "Iteration" , "Time" , trim(self % variable)
!!         close( fID ) 
!              
!      end subroutine Probe_Initialization
!
!      subroutine Probe_Update ( self , mesh , bufferPosition )
!!
!!        ***************************************************************************
!!              This subroutine updates the value of the probe. From the mesh,
!!           it computes the value of the tracked variable by means of an 
!!           interpolation. It is stored in the buffer.
!!        ***************************************************************************
!!        
!         implicit none
!         class(Probe_t)          :: self
!         class(HexMesh)       :: mesh
!         integer                 :: bufferPosition
!!
!!        ---------------
!!        Local variables
!!        ---------------
!!
!         integer                 :: N 
!         real(kind=RP)           :: rho  , rhou  , rhov  , rhoe
!         real(kind=RP)           :: rhot , rhout , rhovt , rhoet
!!      
!!         if ( self % active ) then
!!            N = mesh % elements( self % eID ) % spA % N 
!!!   
!!!           Select the variable
!!!           -------------------
!!            select case ( trim( self % variable ) )
!!   
!!               case ("rho")
!!                  call BilinearForm ( mesh % elements ( self % eID )  % Q    ( IRHO , 0:N , 0:N )  , self % l_xi , self % l_eta , rho   ) 
!!                  self % values(bufferPosition) = rho * refValues % rho
!!    
!!               case ("rhou")
!!                  call BilinearForm ( mesh % elements ( self % eID )  % Q    ( IRHOU , 0:N , 0:N )  , self % l_xi , self % l_eta , rhou  ) 
!!                  self % values(bufferPosition) = rhou * refValues % rho * refValues % a
!!    
!!               case ("rhov")
!!                  call BilinearForm ( mesh % elements ( self % eID )  % Q    ( IRHOV , 0:N , 0:N )  , self % l_xi , self % l_eta , rhov  ) 
!!                  self % values(bufferPosition) = rhov * refValues % rho * refValues % a
!!    
!!               case ("rhoe")
!!                  call BilinearForm ( mesh % elements ( self % eID )  % Q    ( IRHOE , 0:N , 0:N )  , self % l_xi , self % l_eta , rhoe  ) 
!!                  self % values(bufferPosition) = rhoe * refValues % rho * refValues % p
!!    
!!               case ("rhot")
!!                  call BilinearForm ( mesh % elements ( self % eID )  % QDot ( IRHO , 0:N , 0:N  )  , self % l_xi , self % l_eta , rhot  ) 
!!                  self % values(bufferPosition) = rhot * refValues % rho / refValues % tc
!!    
!!               case ("rhout")
!!                  call BilinearForm ( mesh % elements ( self % eID )  % QDot ( IRHOU , 0:N , 0:N )  , self % l_xi , self % l_eta , rhout ) 
!!                  self % values(bufferPosition) = rhout * refValues % rho * refValues % a / refValues % tc
!!    
!!               case ("rhovt")
!!                  call BilinearForm ( mesh % elements ( self % eID )  % QDot ( IRHOV , 0:N , 0:N )  , self % l_xi , self % l_eta , rhovt ) 
!!                  self % values(bufferPosition) = rhovt * refValues % rho * refValues % a / refValues % tc
!!    
!!               case ("rhoet")
!!                  call BilinearForm ( mesh % elements ( self % eID )  % QDot ( IRHOE , 0:N , 0:N  )  , self % l_xi , self % l_eta , rhoet ) 
!!                  self % values(bufferPosition) = rhoet * refValues % rho * refValues % p / refValues % tc
!!    
!!               case ("u")
!!                  call BilinearForm ( mesh % elements ( self % eID )  % Q    ( IRHO  , 0:N , 0:N )  , self % l_xi , self % l_eta , rho   ) 
!!                  call BilinearForm ( mesh % elements ( self % eID )  % Q    ( IRHOU , 0:N , 0:N )  , self % l_xi , self % l_eta , rhou  ) 
!!                  self % values(bufferPosition) = rhou / rho * refValues % a
!!    
!!               case ("v")
!!                  call BilinearForm ( mesh % elements ( self % eID )  % Q    ( IRHO  , 0:N , 0:N )  , self % l_xi , self % l_eta , rho   ) 
!!                  call BilinearForm ( mesh % elements ( self % eID )  % Q    ( IRHOV , 0:N , 0:N )  , self % l_xi , self % l_eta , rhov  ) 
!!                  self % values(bufferPosition) = rhov / rho * refValues % a
!!       
!!               case ("p")
!!                  call BilinearForm ( mesh % elements ( self % eID )  % Q    ( IRHO  , 0:N , 0:N )  , self % l_xi , self % l_eta , rho   ) 
!!                  call BilinearForm ( mesh % elements ( self % eID )  % Q    ( IRHOU , 0:N , 0:N )  , self % l_xi , self % l_eta , rhou  ) 
!!                  call BilinearForm ( mesh % elements ( self % eID )  % Q    ( IRHOV , 0:N , 0:N )  , self % l_xi , self % l_eta , rhov  ) 
!!                  call BilinearForm ( mesh % elements ( self % eID )  % Q    ( IRHOE , 0:N , 0:N )  , self % l_xi , self % l_eta , rhoe  ) 
!!                  self % values(bufferPosition) = Thermodynamics % gm1 * ( rhoe - 0.5_RP * ( rhou * rhou + rhov * rhov ) / rho ) * refValues % p
!!          
!!               case ("Mach")
!!                  call BilinearForm ( mesh % elements ( self % eID )  % Q    ( IRHO  , 0:N , 0:N )  , self % l_xi , self % l_eta , rho   ) 
!!                  call BilinearForm ( mesh % elements ( self % eID )  % Q    ( IRHOU , 0:N , 0:N )  , self % l_xi , self % l_eta , rhou  ) 
!!                  call BilinearForm ( mesh % elements ( self % eID )  % Q    ( IRHOV , 0:N , 0:N )  , self % l_xi , self % l_eta , rhov  ) 
!!                  self % values(bufferPosition) = sqrt(rhou * rhou + rhov * rhov) / rho / sqrt(Thermodynamics % gamma)
!!    
!!               case default
!!   
!!                  if ( len_trim (self % variable) .eq. 0 ) then
!!                     print*, "Variable was not specified for probe " , self % ID , "."
!!                  else
!!                     print*, 'Variable "',trim(self % variable),'" in probe ', self % ID, ' not implemented yet.'
!!                     print*, "Options available are:"
!!                     print*, "   * rho"
!!                     print*, "   * rhou"
!!                     print*, "   * rhov"
!!                     print*, "   * rhoe"
!!                     print*, "   * rhot"
!!                     print*, "   * rhout"
!!                     print*, "   * rhovt"
!!                     print*, "   * rhoet"
!!                     print*, "   * u"
!!                     print*, "   * v"
!!                     print*, "   * p"
!!                     print*, "   * Mach"
!!                     stop "Stopped."
!!   
!!                  end if
!!   
!!            end select                        
!!   
!!         end if
!
!      end subroutine Probe_Update
!
!      subroutine Probe_WriteLabel ( self )
!!
!!        ************************************************************
!!              This subroutine displays the probe label for the time
!!           integrator Display procedure.
!!        ************************************************************
!!
!         implicit none
!         class(Probe_t)             :: self
!!      
!!         if ( self % active ) then
!!            write(STD_OUT , '(3X,A10)' , advance = "no") trim(self % monitorName(1 : MONITOR_LENGTH))
!!         end if
!!
!      end subroutine Probe_WriteLabel
!   
!      subroutine Probe_WriteValue ( self , bufferLine ) 
!!
!!        ***********************************************************
!!              This subroutine displays the probe value for the time
!!           integrator Display procedure.
!!        ***********************************************************
!!
!         implicit none
!         class(Probe_t)             :: self
!         integer                    :: bufferLine
!
!!         if ( self % active ) then
!!            write(STD_OUT , '(1X,A,1X,ES10.3)' , advance = "no") "|" , self % values ( bufferLine ) 
!!         end if
!!
!      end subroutine Probe_WriteValue 
!
!      subroutine Probe_WriteToFile ( self , iter , t , no_of_lines)
!!
!!        *********************************************************************
!!              This subroutine exports the results to the monitor file.
!!           Just "no_of_lines" buffer lines are written.
!!        *********************************************************************
!!
!         implicit none  
!         class(Probe_t)             :: self
!         integer                    :: iter(:)
!         real(kind=RP)              :: t(:)
!         integer                    :: no_of_lines
!!        -------------------------------------------
!         integer                    :: i
!         integer                    :: fID
!
!!         if ( self % active ) then
!!            open( newunit = fID , file = trim ( self % fileName ) , action = "write" , access = "append" , status = "old" )
!!            
!!            do i = 1 , no_of_lines
!!               write( fID , '(I10,2X,ES24.16,2X,ES24.16)' ) iter(i) , t(i) , self % values(i)
!!   
!!            end do
!!           
!!            close ( fID )
!!
!!            self % values(1) = self % values(no_of_lines)
!!         end if
!      
!      end subroutine Probe_WriteToFile
!//////////////////////////////////////////////////////////////////////////////
!
!        Auxiliars
!
!//////////////////////////////////////////////////////////////////////////////
!
   subroutine getNoOfMonitors(no_of_surfaceMonitors, no_of_volumeMonitors)
      use ParamfileRegions
      implicit none
      integer, intent(out)    :: no_of_surfaceMonitors
      integer, intent(out)    :: no_of_volumeMonitors
!
!     ---------------
!     Local variables
!     ---------------
!
      character(len=LINE_LENGTH) :: case_name, line
      integer                    :: fID
      integer                    :: io
!
!     Initialize
!     ----------
      no_of_surfaceMonitors = 0
      no_of_volumeMonitors = 0
!
!     Get case file name
!     ------------------
      call get_command_argument(1, case_name)

!
!     Open case file
!     --------------
      open ( newunit = fID , file = case_name , status = "old" , action = "read" )

!
!     Read the whole file to find monitors
!     ------------------------------------
readloop:do 
         read ( fID , '(A)' , iostat = io ) line

         if ( io .lt. 0 ) then
!
!           End of file
!           -----------
            line = ""
            exit readloop

         elseif ( io .gt. 0 ) then
!
!           Error
!           -----
            errorMessage(STD_OUT)
            stop "Stopped."

         else
!
!           Succeeded
!           ---------
            line = getSquashedLine( line )

            if ( index ( line , '#defineprobe' ) .gt. 0 ) then
!               Monitors % no_of_probes = Monitors % no_of_probes + 1

            elseif ( index ( line , '#definesurfacemonitor' ) .gt. 0 ) then
               no_of_surfaceMonitors = no_of_surfaceMonitors + 1 

            elseif ( index ( line , '#definevolumemonitor' ) .gt. 0 ) then
               no_of_volumeMonitors = no_of_volumeMonitors + 1 

            end if
            
         end if

      end do readloop
!
!     Close case file
!     ---------------
      close(fID)                             


end subroutine getNoOfMonitors

end module MonitorsClass
!
!////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!
!
