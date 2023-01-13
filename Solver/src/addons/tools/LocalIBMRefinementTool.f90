module LocalIBMRefinementTool

   use SMConstants
   use FTValueDictionaryClass
   use LocalRefinementTool
   
   implicit none

   private
   public LocalRef_IBM

!////////////////////////////////////////////////////////////////////////
   contains
!////////////////////////////////////////////////////////////////////////
!
   subroutine LocalRef_IBM(controlVariables)

      use LocalRefinement
      use HexMeshClass
      use SMConstants
      use FTValueDictionaryClass
      use mainKeywordsModule
      use Headers
      use MPI_Process_Info
      use OrientedBoundingBox
      use PhysicsStorage
       
      implicit none
      !-arguemnts----------------------------------------------
      type( FTValueDictionary) :: controlVariables
      !-local-variables----------------------------------------
      character(len=LINE_LENGTH) :: fileName, meshFileName
      type(HexMesh)              :: mesh
      logical                    :: success
      character(len=LINE_LENGTH) :: msg, fname, MyString, &
                                    STLfilename
      integer, allocatable       :: Nx(:), Ny(:), Nz(:)
      real(kind=RP)              :: Naverage
      integer                    :: Nmax, STLnum

      call CheckInputIntegrityIBM(controlVariables, success)
      if(.not. success) error stop "Control file reading error"
!
!     ---------------------------
!     Set up the local refinement
!     --------------------------- 
!
      meshFileName = controlVariables % stringValueForKey("mesh file name", requestedLength = LINE_LENGTH) 
      fileName = controlVariables % stringValueForKey("solution file name", requestedLength = LINE_LENGTH) 

      call GetMeshPolynomialOrders(controlVariables,Nx,Ny,Nz,Nmax)

      call ConstructSimpleMesh_IBM(mesh, meshFileName, Nx, Ny, Nz)
  
!
!     -----------------
!     Describe the mesh
!     -----------------
!
      write(STD_OUT,'(/)')
      call Section_Header("Job description")
      write(msg,'(A,A,A)') 'Mesh file "',trim(meshFileName),'":'
      write(STD_OUT,'(/)')
      call SubSection_Header(trim(msg))
      write(STD_OUT,'(30X,A,A30,I0)') "->", "Number of elements: ", mesh% no_of_elements
      write(STD_OUT,'(/)')
               
      call mesh% IBM% read_info( controlVariables )

      allocate( mesh% IBM% stl(mesh% IBM% NumOfSTL),         &
                mesh% IBM% STLfilename(mesh% IBM% NumOfSTL), &
                OBB(mesh% IBM% NumOfSTL)                     )              
        
      do STLNum = 1,  mesh% IBM% NumOfSTL
         write(MyString, '(i100)') STLNum
         if( STLNum .eq. 1 ) then
            fname = stlFileNameKey
         else
            fname = trim(stlFileNameKey)//trim(adjustl(MyString))
         end if         
         mesh% IBM% STLfilename(STLNum) = controlVariables% stringValueForKey(trim(fname), requestedLength = LINE_LENGTH)
         mesh% IBM% stl(STLNum)% body = STLNum             
         OBB(STLNum)% filename        = mesh% IBM% STLfilename(STLNum)
         call mesh% IBM% stl(STLNum)% ReadTesselation( mesh% IBM% STLfilename(STLNum) )
         call OBB(STLNum)% construct( mesh% IBM% stl(STLNum), .true., mesh% IBM% AAB )
      end do

      call mesh% IBM% SetPolynomialOrder( mesh% elements )
!
!     ---------------------
!     Create the final file
!     ---------------------
!
      call mesh% ExportOrders(meshFileName)
        
      do STLNum = 1,  mesh% IBM% NumOfSTL
         call mesh% IBM% stl(STLNum)% destroy()
      end do
        
      deallocate( mesh% IBM% stl, mesh% IBM% STLfilename, OBB )

      Naverage = sum( mesh% elements(1:size(mesh% elements))% Nxyz(1) + &
                      mesh% elements(1:size(mesh% elements))% Nxyz(2) + &
                      mesh% elements(1:size(mesh% elements))% Nxyz(3)   )/(3.0_RP * mesh% no_of_elements)

      call Subsection_Header("omesh file")

      write(STD_OUT,'(30X,A,A30,F5.2)')      "->   ", "Average polynomial order: ", Naverage
      write(STD_OUT,'(30X,A,A30,I0)')      "->   ", "Degrees of Freedom (NDOF): ",  &
      sum( (mesh% elements(1:size(mesh% elements))% Nxyz(1)+1)* &
           (mesh% elements(1:size(mesh% elements))% Nxyz(2)+1)* &
           (mesh% elements(1:size(mesh% elements))% Nxyz(3)+1)  )

   end subroutine LocalRef_IBM

   subroutine ConstructSimpleMesh_IBM(mesh, meshFileName, Nx_, Ny_, Nz_)

      use SMConstants
      use Headers
      use HexMeshClass
      use LocalRefinement
      use readHDF5
      use readSpecM
      use readGMSH
      use FileReadingUtilities, only: getFileExtension
      implicit none
      !-arguments----------------------------------------------
      type(HexMesh)               :: mesh
      character(len=*)            :: meshFileName
      integer,         intent(in) :: Nx_(:), Ny_(:), Nz_(:)
      !-local-variables----------------------------------------
      integer                    :: gmsh_version
      character(len=LINE_LENGTH) :: ext

      ext = getFileExtension(trim(meshFileName))
      if (trim(ext)=='h5') then
         call ConstructSimpleMesh_FromHDF5File_(mesh, meshFileName, Nx=Nx_, Ny=Ny_, Nz=Nz_)
      elseif (trim(ext)=='mesh') then
         call ConstructSimpleMesh_FromSpecFile_(mesh, meshFileName, Nx=Nx_, Ny=Ny_, Nz=Nz_)
      elseif (trim(ext)=='msh') then
         call CheckGMSHversion (meshFileName, gmsh_version)
         select case (gmsh_version)
            case (4)
               call ConstructSimpleMesh_FromGMSHFile_v4_( mesh, meshFileName, Nx_, Ny_, Nz_ )
            case (2)
               call ConstructSimpleMesh_FromGMSHFile_v2_( mesh, meshFileName, Nx_, Ny_, Nz_ )
            case default
               error stop "ReadMeshFile :: Unrecognized GMSH version."
         end select
      else
         error stop 'Mesh file extension not recognized.'
      end if

   end subroutine ConstructSimpleMesh_IBM

   subroutine CheckInputIntegrityIBM( controlVariables, success )
      use ParamfileRegions
      implicit none 
      !-arguments--------------------------------------------------
      type(FTValueDictionary), intent(inout) :: controlVariables
      logical,                 intent(out)   :: success
      !-local-variables--------------------------------------------
      real(kind=rp), allocatable :: BandRegionCoeff_in
      integer,       allocatable :: Nx_in, Ny_in, Nz_in
      character(len=LINE_LENGTH) :: in_label, paramFile

      write(in_label , '(A)') "#define ibm"
      call get_command_argument(1, paramFile)
      call readValueInRegion( trim( paramFile ), "nx",                Nx_in,               in_label, "#end" )
      call readValueInRegion( trim( paramFile ), "ny",                Ny_in,               in_label, "#end" )
      call readValueInRegion( trim( paramFile ), "nz",                Nz_in,               in_label, "#end" )
      call readValueInRegion( trim( paramFile ), "band region coeff", BandRegionCoeff_in,  in_label, "#end" ) 

      if( .not. allocated(Nx_in) ) then
         print*, "Missing keyword 'nx' in input file"
         success = .false.
         return
      end if   
           
      if( .not. allocated(Ny_in) ) then
         print*, "Missing keyword 'ny' in input file"
         success = .false.
         return
      end if 
             
      if( .not. allocated(Nz_in) ) then
         print*, "Missing keyword 'nz' in input file"
         success = .false.
         return
      end if  

      if( .not. allocated(BandRegionCoeff_in) ) then
         print*, "Missing keyword 'band region coeff' in input file"
         success = .false.
         return
      end if 

      success = .true.

   end subroutine CheckInputIntegrityIBM


end module LocalIBMRefinementTool
